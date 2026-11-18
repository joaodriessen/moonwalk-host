#pragma once

#include <boost/asio/steady_timer.hpp>
#include <cstdint>
#include <memory>
#include <mutex>

namespace rtsp_stream {
  // Actual pending-RTSP queue and timer, independently exercisable without
  // binding the production server or creating a stream/display.
  template<class Session>
  class pending_launch_queue_t {
  public:
    explicit pending_launch_queue_t(boost::asio::io_context &io):
        timer_(io) {}

    ~pending_launch_queue_t() {
      discard();
    }

    template<class Duration>
    bool raise(std::shared_ptr<Session> session, Duration timeout) {
      std::lock_guard lock(state_->mutex);
      if (state_->current) {
        return false;
      }
      state_->current = session;
      timer_.expires_after(timeout);
      timer_.async_wait([state = state_, session](const boost::system::error_code &ec) {
        if (ec) {
          return;
        }
        {
          std::lock_guard lock(state->mutex);
          // Compare identity, not just an ID: even a queued successful handler
          // from a retired timer must not pop a subsequent pending launch.
          if (state->current != session) {
            return;
          }
          state->current.reset();
        }
        session->pending.expire();
      });
      return true;
    }

    std::shared_ptr<Session> current() {
      std::lock_guard lock(state_->mutex);
      return state_->current;
    }

    void clear(uint32_t id) {
      std::shared_ptr<Session> retired;
      {
        std::lock_guard lock(state_->mutex);
        if (!state_->current || state_->current->id != id) {
          return;
        }
        timer_.cancel();
        retired = std::move(state_->current);
      }
      retired->pending.expire();
    }

    void discard() {
      std::shared_ptr<Session> retired;
      {
        std::lock_guard lock(state_->mutex);
        timer_.cancel();
        retired = std::move(state_->current);
      }
      if (retired) {
        retired->pending.expire();
      }
    }

  private:
    struct state_t {
      std::mutex mutex;
      std::shared_ptr<Session> current;
    };

    // A queued completion may outlive the queue after cancellation. Its state
    // stays valid without retaining or dereferencing the server object.
    std::shared_ptr<state_t> state_ = std::make_shared<state_t>();
    boost::asio::steady_timer timer_;
  };
}  // namespace rtsp_stream
