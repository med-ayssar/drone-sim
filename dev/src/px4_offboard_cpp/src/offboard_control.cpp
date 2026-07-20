// Minimal PX4 offboard control example (ROS 2, C++).
//
// Flow:
//   1. Stream OffboardControlMode + TrajectorySetpoint at >2 Hz.
//   2. After ~1 s of streaming, request Offboard mode and arm -- and keep
//      retrying once a second until PX4 confirms both (a single dropped or
//      too-early command otherwise leaves the vehicle armed but idle).
//   3. Climb straight up to 5 m (PX4 uses NED so z = -5), fly out to the first
//      waypoint A, then trace the single circle that passes through the three
//      waypoints A, B, C (its circumcircle) so the drone loops through all
//      three points instead of spinning in place.
//   4. Subscribe to VehicleLocalPosition / VehicleStatus to observe state.
//
// PX4 topics (v1.14+): /fmu/in/* are commands INTO PX4, /fmu/out/* come OUT.
// Requires the micro-XRCE-DDS Agent running and PX4 SITL connected.

#include <px4_msgs/msg/offboard_control_mode.hpp>
#include <px4_msgs/msg/trajectory_setpoint.hpp>
#include <px4_msgs/msg/vehicle_command.hpp>
#include <px4_msgs/msg/vehicle_local_position.hpp>
#include <px4_msgs/msg/vehicle_status.hpp>
#include <rclcpp/rclcpp.hpp>

#include <chrono>
#include <cmath>
#include <cstdint>

using namespace std::chrono_literals;
using namespace px4_msgs::msg;

class OffboardControl : public rclcpp::Node
{
public:
  OffboardControl()
  : Node("offboard_control")
  {
    // PX4 publishes /fmu/out/* with best-effort, keep-last QoS. Subscribers
    // MUST match or they receive nothing.
    rclcpp::QoS px4_qos(rclcpp::KeepLast(5));
    px4_qos.best_effort();
    px4_qos.durability_volatile();

    // --- Publishers: commands into PX4 ---
    offboard_mode_pub_ =
      create_publisher<OffboardControlMode>("/fmu/in/offboard_control_mode", 10);
    trajectory_pub_ =
      create_publisher<TrajectorySetpoint>("/fmu/in/trajectory_setpoint", 10);
    vehicle_command_pub_ =
      create_publisher<VehicleCommand>("/fmu/in/vehicle_command", 10);

    // --- Subscribers: state out of PX4 ---
    local_position_sub_ = create_subscription<VehicleLocalPosition>(
      "/fmu/out/vehicle_local_position", px4_qos,
      [this](const VehicleLocalPosition::SharedPtr msg) {
        last_x_ = msg->x;
        last_y_ = msg->y;
        last_z_ = msg->z;
      });

    vehicle_status_sub_ = create_subscription<VehicleStatus>(
      "/fmu/out/vehicle_status", px4_qos,
      [this](const VehicleStatus::SharedPtr msg) {
        armed_ = (msg->arming_state == VehicleStatus::ARMING_STATE_ARMED);
        nav_state_ = msg->nav_state;
        preflight_ok_ = msg->pre_flight_checks_pass;
      });

    compute_circumcircle();

    timer_ = create_wall_timer(100ms, [this]() { on_timer(); });
    RCLCPP_INFO(
      get_logger(),
      "Offboard control node started. Circle through A/B/C: centre=(%.2f, %.2f) "
      "radius=%.2f m dir=%s",
      cx_, cy_, radius_, dir_ > 0 ? "CCW" : "CW");
  }

  // Solve the circle that passes through the three waypoints (their
  // circumcircle) and pick the sweep direction that visits A -> B -> C in order.
  void compute_circumcircle()
  {
    const float ax = kWaypoints[0][0], ay = kWaypoints[0][1];
    const float bx = kWaypoints[1][0], by = kWaypoints[1][1];
    const float cx = kWaypoints[2][0], cy = kWaypoints[2][1];

    const float d =
      2.0f * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    if (std::fabs(d) < 1e-6f) {
      // Collinear points have no finite circle -- fall back to a circle centred
      // on A so the node still does something sane instead of dividing by ~0.
      cx_ = ax;
      cy_ = ay;
      radius_ = kRadius;
      dir_ = 1.0;
    } else {
      const float a2 = ax * ax + ay * ay;
      const float b2 = bx * bx + by * by;
      const float c2 = cx * cx + cy * cy;
      cx_ = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d;
      cy_ = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d;
      radius_ = std::hypot(ax - cx_, ay - cy_);
      // Signed area of triangle ABC: positive => A->B->C is counter-clockwise.
      const float cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
      dir_ = (cross >= 0.0f) ? 1.0 : -1.0;
    }
    theta0_ = std::atan2(ay - cy_, ax - cx_);  // angle of A on the circle
  }

private:
  enum class Phase { Climb, GotoStart, Circle };

  void on_timer()
  {
    // These two must be streamed continuously or PX4 drops out of Offboard.
    publish_offboard_control_mode();
    publish_trajectory_setpoint();

    // Handshake: after a short warmup so PX4 has seen enough offboard signals,
    // request Offboard mode and arm. Retry once a second until PX4 reports it
    // is actually in Offboard / armed -- retrying is the key to not getting
    // stuck "armed but idle" when the first command is dropped or too early.
    if (tick_ >= kWarmupTicks && tick_ % kRetryTicks == 0) {
      if (nav_state_ != VehicleStatus::NAVIGATION_STATE_OFFBOARD) {
        engage_offboard_mode();
      }
      // Only arm once PX4 reports its preflight checks pass -- otherwise the
      // commander denies arming ("Resolve system health failures first"). If it
      // never passes, the *specific* failing check is printed in the PX4 SITL
      // console (start.sh tab 0) or shown in QGC -- fix that, not this node.
      if (!armed_ && preflight_ok_) {
        arm();
      } else if (!armed_ && !preflight_ok_) {
        RCLCPP_WARN(
          get_logger(),
          "Waiting to arm: PX4 preflight checks not passing yet "
          "(check the PX4 console / QGC for the specific failure).");
      }
    }

    // Status heartbeat once a second so progress is visible.
    if (tick_ % 10 == 0) {
      RCLCPP_INFO(
        get_logger(),
        "armed=%s preflight_ok=%s nav_state=%u alt=%.2f m (target %.1f) phase=%s",
        armed_ ? "yes" : "no", preflight_ok_ ? "yes" : "no", nav_state_, -last_z_,
        static_cast<double>(kTakeoffAlt), phase_name(phase_));
    }

    ++tick_;
  }

  void publish_offboard_control_mode()
  {
    OffboardControlMode msg{};
    msg.position = true;     // we command position setpoints
    msg.velocity = false;
    msg.acceleration = false;
    msg.attitude = false;
    msg.body_rate = false;
    msg.timestamp = now_us();
    offboard_mode_pub_->publish(msg);
  }

  void publish_trajectory_setpoint()
  {
    TrajectorySetpoint msg{};

    switch (phase_) {
      case Phase::Climb: {
        // Climb straight up at the origin until we're near target altitude.
        // Time fallback (kCircleStartTick) guards against a missing position
        // feed stranding us in the climb.
        msg.position = {0.0f, 0.0f, -kTakeoffAlt};
        msg.yaw = static_cast<float>(theta0_ + dir_ * kPi / 2.0);  // face toward A
        const bool reached_alt = std::fabs(-last_z_ - kTakeoffAlt) < 0.5f;
        if ((armed_ && reached_alt) || tick_ >= kCircleStartTick) {
          phase_ = Phase::GotoStart;
          phase_start_tick_ = tick_;
        }
        break;
      }
      case Phase::GotoStart: {
        // Fly out to waypoint A (the circle entry point) before sweeping, so the
        // drone eases onto the ring instead of jumping to the far side of it.
        const float ax = kWaypoints[0][0], ay = kWaypoints[0][1];
        msg.position = {ax, ay, -kTakeoffAlt};
        msg.yaw = static_cast<float>(theta0_ + dir_ * kPi / 2.0);
        const bool reached = std::hypot(last_x_ - ax, last_y_ - ay) < 0.5f;
        if (reached || tick_ - phase_start_tick_ >= kGotoTimeoutTicks) {
          phase_ = Phase::Circle;
          theta_ = theta0_;
        }
        break;
      }
      case Phase::Circle: {
        // Trace the circumcircle through A, B, C. Yaw follows the tangent so the
        // nose points along the direction of travel.
        theta_ += dir_ * kOmega * kDt;
        const float x = cx_ + radius_ * std::cos(theta_);
        const float y = cy_ + radius_ * std::sin(theta_);
        msg.position = {x, y, -kTakeoffAlt};
        msg.yaw = wrap_pi(static_cast<float>(theta_ + dir_ * kPi / 2.0));
        break;
      }
    }

    msg.timestamp = now_us();
    trajectory_pub_->publish(msg);
  }

  static const char * phase_name(Phase p)
  {
    switch (p) {
      case Phase::Climb:     return "climb";
      case Phase::GotoStart: return "goto-A";
      case Phase::Circle:    return "circle";
    }
    return "?";
  }

  static float wrap_pi(float angle)
  {
    while (angle > kPi) { angle -= 2.0f * kPi; }
    while (angle < -kPi) { angle += 2.0f * kPi; }
    return angle;
  }

  void publish_vehicle_command(uint16_t command, float param1 = 0.0f, float param2 = 0.0f)
  {
    VehicleCommand msg{};
    msg.command = command;
    msg.param1 = param1;
    msg.param2 = param2;
    msg.target_system = 1;
    msg.target_component = 1;
    msg.source_system = 1;
    msg.source_component = 1;
    msg.from_external = true;
    msg.timestamp = now_us();
    vehicle_command_pub_->publish(msg);
  }

  void arm()
  {
    publish_vehicle_command(VehicleCommand::VEHICLE_CMD_COMPONENT_ARM_DISARM, 1.0f);
    RCLCPP_INFO(get_logger(), "Arm command sent");
  }

  void disarm()
  {
    publish_vehicle_command(VehicleCommand::VEHICLE_CMD_COMPONENT_ARM_DISARM, 0.0f);
    RCLCPP_INFO(get_logger(), "Disarm command sent");
  }

  void engage_offboard_mode()
  {
    // base_mode = 1 (custom), custom_main_mode = 6 (Offboard)
    publish_vehicle_command(VehicleCommand::VEHICLE_CMD_DO_SET_MODE, 1.0f, 6.0f);
    RCLCPP_INFO(get_logger(), "Offboard mode requested");
  }

  uint64_t now_us()
  {
    return static_cast<uint64_t>(get_clock()->now().nanoseconds() / 1000);
  }

  rclcpp::Publisher<OffboardControlMode>::SharedPtr offboard_mode_pub_;
  rclcpp::Publisher<TrajectorySetpoint>::SharedPtr trajectory_pub_;
  rclcpp::Publisher<VehicleCommand>::SharedPtr vehicle_command_pub_;
  rclcpp::Subscription<VehicleLocalPosition>::SharedPtr local_position_sub_;
  rclcpp::Subscription<VehicleStatus>::SharedPtr vehicle_status_sub_;
  rclcpp::TimerBase::SharedPtr timer_;

  // Waypoints A, B, C in the local NED-ish frame (metres, x/y relative to
  // launch). Edit these to change the loop -- the circle through them is solved
  // at startup in compute_circumcircle().
  static constexpr float kWaypoints[3][2] = {
    { 5.0f,  0.0f},   // A
    { 0.0f,  5.0f},   // B
    {-5.0f,  0.0f},   // C
  };

  // Handshake / trajectory parameters (timer runs at 10 Hz, so 10 ticks = 1 s).
  static constexpr uint64_t kWarmupTicks      = 10;   // stream ~1 s before handshake
  static constexpr uint64_t kRetryTicks       = 10;   // re-request offboard/arm every 1 s
  static constexpr uint64_t kCircleStartTick  = 120;  // ~12 s fallback to leave climb
  static constexpr uint64_t kGotoTimeoutTicks = 100;  // ~10 s fallback to start circling
  static constexpr float  kTakeoffAlt = 5.0f;   // metres above launch
  static constexpr float  kRadius     = 5.0f;   // fallback radius if points collinear
  static constexpr double kOmega      = 0.3;    // angular rate, rad/s (~21 s/lap)
  static constexpr double kDt         = 0.1;    // timer period, s (10 Hz)
  static constexpr float  kPi         = 3.14159265358979323846f;

  // Circle solved from the waypoints at startup.
  float cx_ = 0.0f, cy_ = 0.0f;   // circle centre
  float radius_ = kRadius;
  double dir_ = 1.0;              // +1 = CCW, -1 = CW (to visit A->B->C in order)
  double theta0_ = 0.0;          // angle of waypoint A on the circle

  uint64_t tick_ = 0;       // free-running 10 Hz loop counter
  uint64_t phase_start_tick_ = 0;
  bool armed_ = false;
  bool preflight_ok_ = false;   // PX4 reports preflight/health checks pass
  uint8_t nav_state_ = 0;
  float last_x_ = 0.0f;
  float last_y_ = 0.0f;
  float last_z_ = 0.0f;
  Phase phase_ = Phase::Climb;
  double theta_ = 0.0;      // current angle along the circle, rad
};

int main(int argc, char * argv[])
{
  setvbuf(stdout, nullptr, _IONBF, BUFSIZ);
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<OffboardControl>());
  rclcpp::shutdown();
  return 0;
}
