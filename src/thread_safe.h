/**
 * @file src/thread_safe.h
 * @brief Declarations for thread-safe data structures.
 */
#pragma once

// standard includes
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <map>
#include <mutex>
#include <vector>

// local includes
#include "utility.h"

namespace safe {
  template<class T>
  class event_t {
  public:
    using status_t = util::optional_t<T>;

    template<class... Args>
    void raise(Args &&...args) {
      std::lock_guard lg {_lock};
      if (!_continue) {
        return;
      }

      // Phase-0 perf_trace instrumentation (docs/design/pipeline-overhaul.md §2 "D" mbox_drop).
      // _status already holds an unconsumed value that is about to be overwritten below -- count
      // it. Per-instance counter (each event_t<T>, e.g. the video mailbox vs. idr_events vs.
      // shutdown_event, carries its own independent std::atomic starting at 0), read via
      // exchange_mbox_drop_count(); purely additive under the existing lock and does not alter
      // raise()'s control flow, timing, or the overwrite below in any way.
      if (_status) {
        _mbox_drop_count.fetch_add(1, std::memory_order_relaxed);
      }

      if constexpr (std::is_same_v<std::optional<T>, status_t>) {
        _status = std::make_optional<T>(std::forward<Args>(args)...);
      } else {
        _status = status_t {std::forward<Args>(args)...};
      }

      _cv.notify_all();
    }

    // Phase-0 perf_trace instrumentation: atomically read-and-reset this instance's mbox_drop
    // counter (see raise() above). Relaxed ordering is fine -- this is a rolling 1s observability
    // counter, not a synchronization primitive.
    std::size_t exchange_mbox_drop_count() {
      return _mbox_drop_count.exchange(0, std::memory_order_relaxed);
    }

    // pop and view should not be used interchangeably
    status_t pop() {
      std::unique_lock ul {_lock};

      if (!_continue) {
        return util::false_v<status_t>;
      }

      while (!_status) {
        _cv.wait(ul);

        if (!_continue) {
          return util::false_v<status_t>;
        }
      }

      auto val = std::move(_status);
      _status = util::false_v<status_t>;
      return val;
    }

    // pop and view should not be used interchangeably
    template<class Rep, class Period>
    status_t pop(std::chrono::duration<Rep, Period> delay) {
      std::unique_lock ul {_lock};

      if (!_continue) {
        return util::false_v<status_t>;
      }

      while (!_status) {
        if (!_continue || _cv.wait_for(ul, delay) == std::cv_status::timeout) {
          return util::false_v<status_t>;
        }
      }

      auto val = std::move(_status);
      _status = util::false_v<status_t>;
      return val;
    }

    // pop and view should not be used interchangeably
    status_t view() {
      std::unique_lock ul {_lock};

      if (!_continue) {
        return util::false_v<status_t>;
      }

      while (!_status) {
        _cv.wait(ul);

        if (!_continue) {
          return util::false_v<status_t>;
        }
      }

      return _status;
    }

    // pop and view should not be used interchangeably
    template<class Rep, class Period>
    status_t view(std::chrono::duration<Rep, Period> delay) {
      std::unique_lock ul {_lock};

      if (!_continue) {
        return util::false_v<status_t>;
      }

      while (!_status) {
        if (!_continue || _cv.wait_for(ul, delay) == std::cv_status::timeout) {
          return util::false_v<status_t>;
        }
      }

      return _status;
    }

    bool peek() {
      return _continue && (bool) _status;
    }

    void stop() {
      std::lock_guard lg {_lock};

      _continue = false;

      _cv.notify_all();
    }

    void reset() {
      std::lock_guard lg {_lock};

      _continue = true;

      _status = util::false_v<status_t>;
    }

    [[nodiscard]] bool running() const {
      return _continue;
    }

  private:
    bool _continue {true};
    status_t _status {util::false_v<status_t>};

    std::condition_variable _cv;
    std::mutex _lock;

    // Phase-0 perf_trace instrumentation (docs/design/pipeline-overhaul.md §2 "D"). Per-instance,
    // zero-initialized; only ever touched by raise()/exchange_mbox_drop_count() above. An
    // event_t<T> instance nobody calls exchange_mbox_drop_count() on simply carries a counter
    // nobody reads -- zero effect on that instance's behavior.
    std::atomic<std::size_t> _mbox_drop_count {0};
  };

  template<class T>
  class alarm_raw_t {
  public:
    using status_t = util::optional_t<T>;

    void ring(const status_t &status) {
      std::lock_guard lg(_lock);

      _status = status;
      _rang = true;
      _cv.notify_one();
    }

    void ring(status_t &&status) {
      std::lock_guard lg(_lock);

      _status = std::move(status);
      _rang = true;
      _cv.notify_one();
    }

    template<class Rep, class Period>
    auto wait_for(const std::chrono::duration<Rep, Period> &rel_time) {
      std::unique_lock ul(_lock);

      return _cv.wait_for(ul, rel_time, [this]() {
        return _rang;
      });
    }

    template<class Rep, class Period, class Pred>
    auto wait_for(const std::chrono::duration<Rep, Period> &rel_time, Pred &&pred) {
      std::unique_lock ul(_lock);

      return _cv.wait_for(ul, rel_time, [this, &pred]() {
        return _rang || pred();
      });
    }

    template<class Rep, class Period>
    auto wait_until(const std::chrono::duration<Rep, Period> &rel_time) {
      std::unique_lock ul(_lock);

      return _cv.wait_until(ul, rel_time, [this]() {
        return _rang;
      });
    }

    template<class Rep, class Period, class Pred>
    auto wait_until(const std::chrono::duration<Rep, Period> &rel_time, Pred &&pred) {
      std::unique_lock ul(_lock);

      return _cv.wait_until(ul, rel_time, [this, &pred]() {
        return _rang || pred();
      });
    }

    auto wait() {
      std::unique_lock ul(_lock);
      _cv.wait(ul, [this]() {
        return _rang;
      });
    }

    template<class Pred>
    auto wait(Pred &&pred) {
      std::unique_lock ul(_lock);
      _cv.wait(ul, [this, &pred]() {
        return _rang || pred();
      });
    }

    const status_t &status() const {
      return _status;
    }

    status_t &status() {
      return _status;
    }

    void reset() {
      _status = status_t {};
      _rang = false;
    }

  private:
    std::mutex _lock;
    std::condition_variable _cv;

    status_t _status {util::false_v<status_t>};
    bool _rang {false};
  };

  template<class T>
  using alarm_t = std::shared_ptr<alarm_raw_t<T>>;

  template<class T>
  alarm_t<T> make_alarm() {
    return std::make_shared<alarm_raw_t<T>>();
  }

  template<class T>
  class queue_t {
  public:
    using status_t = util::optional_t<T>;

    queue_t(std::uint32_t max_elements = 32):
        _max_elements {max_elements} {
    }

    template<class... Args>
    void raise(Args &&...args) {
      std::lock_guard ul {_lock};

      if (!_continue) {
        return;
      }

      if (_queue.size() == _max_elements) {
        _queue.clear();
      }

      _queue.emplace_back(std::forward<Args>(args)...);

      _cv.notify_all();
    }

    // Adaptive video must preserve encoded reference chains rather than invoke
    // raise()'s overflow policy. Wait without moving the packet until accepted.
    template<class Cancel, class... Args>
    bool raise_wait(std::size_t max_pending, Cancel &&cancelled, Args &&...args) {
      std::unique_lock ul {_lock};
      if (!max_pending) return false;
      while (_continue && _queue.size() >= max_pending && !cancelled()) {
        // Session shutdown can occur while another session keeps this shared
        // queue running. Bound that cancellation check without another thread.
        _cv.wait_for(ul, std::chrono::milliseconds(20));
      }
      if (!_continue || cancelled()) return false;
      _queue.emplace_back(std::forward<Args>(args)...);
      _cv.notify_all();
      return true;
    }

    bool peek() {
      return _continue && !_queue.empty();
    }

    template<class Rep, class Period>
    status_t pop(std::chrono::duration<Rep, Period> delay) {
      std::unique_lock ul {_lock};

      if (!_continue) {
        return util::false_v<status_t>;
      }

      while (_queue.empty()) {
        if (!_continue || _cv.wait_for(ul, delay) == std::cv_status::timeout) {
          return util::false_v<status_t>;
        }
      }

      auto val = std::move(_queue.front());
      _queue.erase(std::begin(_queue));
      _cv.notify_all();

      return val;
    }

    status_t pop() {
      std::unique_lock ul {_lock};

      if (!_continue) {
        return util::false_v<status_t>;
      }

      while (_queue.empty()) {
        _cv.wait(ul);

        if (!_continue) {
          return util::false_v<status_t>;
        }
      }

      auto val = std::move(_queue.front());
      _queue.erase(std::begin(_queue));
      _cv.notify_all();

      return val;
    }

    std::vector<T> &unsafe() {
      return _queue;
    }

    void stop() {
      std::lock_guard lg {_lock};

      _continue = false;

      _cv.notify_all();
    }

    [[nodiscard]] bool running() const {
      return _continue;
    }

  private:
    bool _continue {true};
    std::uint32_t _max_elements;

    std::mutex _lock;
    std::condition_variable _cv;

    std::vector<T> _queue;
  };

  template<class T>
  class shared_t {
  public:
    using element_type = T;

    using construct_f = std::function<int(element_type &)>;
    using destruct_f = std::function<void(element_type &)>;

    struct ptr_t {
      shared_t *owner;

      ptr_t():
          owner {nullptr} {
      }

      explicit ptr_t(shared_t *owner):
          owner {owner} {
      }

      ptr_t(ptr_t &&ptr) noexcept:
          owner {ptr.owner} {
        ptr.owner = nullptr;
      }

      ptr_t(const ptr_t &ptr) noexcept:
          owner {ptr.owner} {
        if (!owner) {
          return;
        }

        auto tmp = ptr.owner->ref();
        tmp.owner = nullptr;
      }

      ptr_t &operator=(const ptr_t &ptr) noexcept {
        if (!ptr.owner) {
          release();

          return *this;
        }

        return *this = std::move(*ptr.owner->ref());
      }

      ptr_t &operator=(ptr_t &&ptr) noexcept {
        if (owner) {
          release();
        }

        std::swap(owner, ptr.owner);

        return *this;
      }

      ~ptr_t() {
        if (owner) {
          release();
        }
      }

      operator bool() const {
        return owner != nullptr;
      }

      void release() {
        std::lock_guard lg {owner->_lock};

        if (!--owner->_count) {
          owner->_destruct(*get());
          (*this)->~element_type();
        }

        owner = nullptr;
      }

      element_type *get() const {
        return reinterpret_cast<element_type *>(owner->_object_buf.data());
      }

      element_type *operator->() {
        return reinterpret_cast<element_type *>(owner->_object_buf.data());
      }
    };

    template<class FC, class FD>
    shared_t(FC &&fc, FD &&fd):
        _construct {std::forward<FC>(fc)},
        _destruct {std::forward<FD>(fd)},
        _count {0} {
    }

    [[nodiscard]] ptr_t ref() {
      std::lock_guard lg {_lock};

      if (!_count) {
        new (_object_buf.data()) element_type;
        // The initializer may have acquired RAII resources before failing. Do not
        // call the success-only shutdown hook (its threads may not exist yet), but
        // always destroy this partial element before a later ref() retries it.
        auto failed_init = util::fail_guard([this]() {
          reinterpret_cast<element_type *>(_object_buf.data())->~element_type();
        });
        if (_construct(*reinterpret_cast<element_type *>(_object_buf.data()))) {
          return ptr_t {nullptr};
        }
        failed_init.disable();
      }

      ++_count;

      return ptr_t {this};
    }

  private:
    construct_f _construct;
    destruct_f _destruct;

    std::array<std::uint8_t, sizeof(element_type)> _object_buf;

    std::uint32_t _count;
    std::mutex _lock;
  };

  template<class T, class F_Construct, class F_Destruct>
  auto make_shared(F_Construct &&fc, F_Destruct &&fd) {
    return shared_t<T> {
      std::forward<F_Construct>(fc),
      std::forward<F_Destruct>(fd)
    };
  }

  using signal_t = event_t<bool>;

  class mail_raw_t;
  using mail_t = std::shared_ptr<mail_raw_t>;

  void cleanup(mail_raw_t *);

  template<class T>
  class post_t: public T {
  public:
    template<class... Args>
    post_t(mail_t mail, Args &&...args):
        T(std::forward<Args>(args)...),
        mail {std::move(mail)} {
    }

    mail_t mail;

    ~post_t() {
      cleanup(mail.get());
    }
  };

  template<class T>
  inline auto lock(const std::weak_ptr<void> &wp) {
    return std::reinterpret_pointer_cast<typename T::element_type>(wp.lock());
  }

  class mail_raw_t: public std::enable_shared_from_this<mail_raw_t> {
  public:
    template<class T>
    using event_t = std::shared_ptr<post_t<event_t<T>>>;

    template<class T>
    using queue_t = std::shared_ptr<post_t<queue_t<T>>>;

    template<class T>
    event_t<T> event(const std::string_view &id) {
      std::lock_guard lg {mutex};

      auto it = id_to_post.find(id);
      if (it != std::end(id_to_post)) {
        return lock<event_t<T>>(it->second);
      }

      auto post = std::make_shared<typename event_t<T>::element_type>(shared_from_this());
      id_to_post.emplace(std::pair<std::string, std::weak_ptr<void>> {std::string {id}, post});

      return post;
    }

    template<class T>
    queue_t<T> queue(const std::string_view &id) {
      std::lock_guard lg {mutex};

      auto it = id_to_post.find(id);
      if (it != std::end(id_to_post)) {
        return lock<queue_t<T>>(it->second);
      }

      auto post = std::make_shared<typename queue_t<T>::element_type>(shared_from_this(), 32);
      id_to_post.emplace(std::pair<std::string, std::weak_ptr<void>> {std::string {id}, post});

      return post;
    }

    void cleanup() {
      std::lock_guard lg {mutex};

      for (auto it = std::begin(id_to_post); it != std::end(id_to_post); ++it) {
        auto &weak = it->second;

        if (weak.expired()) {
          id_to_post.erase(it);

          return;
        }
      }
    }

    std::mutex mutex;

    std::map<std::string, std::weak_ptr<void>, std::less<>> id_to_post;
  };

  inline void cleanup(mail_raw_t *mail) {
    mail->cleanup();
  }
}  // namespace safe
