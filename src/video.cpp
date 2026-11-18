/**
 * @file src/video.cpp
 * @brief Definitions for video.
 */
// standard includes
#include <atomic>
#include <bitset>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <list>
#include <map>
#include <thread>

// lib includes
#include <boost/pointer_cast.hpp>

extern "C" {
#include <libavutil/imgutils.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
}

// local includes
#include "cbs.h"
#include "config.h"
#include "display_device.h"
#include "globals.h"
#include "input.h"
#include "logging.h"
#include "nvenc/nvenc_base.h"
#include "platform/common.h"
#include "sync.h"
#include "video.h"
#include "platform/macos/capture_recovery.h"

#ifdef _WIN32
extern "C" {
  #include <libavutil/hwcontext_d3d11va.h>
}
#endif

#ifdef __APPLE__
  // Phase-0 perf_trace instrumentation (docs/design/pipeline-overhaul.md §2): sck_real/sck_idle
  // counters live in the macOS SCK capture callback; this brings in the C-linkage
  // read-and-reset accessors used by the [perf] summary in encode_run() below.
  #include "platform/macos/perf_trace.h"
#endif

using namespace std::literals;

namespace video {

  namespace {
    /**
     * @brief Check if we can allow probing for the encoders.
     * @return True if there should be no issues with the probing, false if we should prevent it.
     */
    bool allow_encoder_probing() {
      const auto devices {display_device::enumerate_devices()};

      // If there are no devices, then either the API is not working correctly or OS does not support the lib.
      // Either way we should not block the probing in this case as we can't tell what's wrong.
      if (devices.empty()) {
        return true;
      }

      // Since Windows 11 24H2, it is possible that there will be no active devices present
      // for some reason (probably a bug). Trying to probe encoders in such a state locks/breaks the DXGI
      // and also the display device for Windows. So we must have at least 1 active device.
      const bool at_least_one_device_is_active = std::any_of(std::begin(devices), std::end(devices), [](const auto &device) {
        // If device has additional info, it is active.
        return static_cast<bool>(device.m_info);
      });

      if (at_least_one_device_is_active) {
        return true;
      }

      BOOST_LOG(error) << "No display devices are active at the moment! Cannot probe the encoders.";
      return false;
    }
  }  // namespace

  void free_ctx(AVCodecContext *ctx) {
    avcodec_free_context(&ctx);
  }

  void free_frame(AVFrame *frame) {
    av_frame_free(&frame);
  }

  void free_buffer(AVBufferRef *ref) {
    av_buffer_unref(&ref);
  }

  namespace nv {

    enum class profile_h264_e : int {
      high = 2,  ///< High profile
      high_444p = 3,  ///< High 4:4:4 Predictive profile
    };

    enum class profile_hevc_e : int {
      main = 0,  ///< Main profile
      main_10 = 1,  ///< Main 10 profile
      rext = 2,  ///< Rext profile
    };

  }  // namespace nv

  namespace qsv {

    enum class profile_h264_e : int {
      high = 100,  ///< High profile
      high_444p = 244,  ///< High 4:4:4 Predictive profile
    };

    enum class profile_hevc_e : int {
      main = 1,  ///< Main profile
      main_10 = 2,  ///< Main 10 profile
      rext = 4,  ///< RExt profile
    };

    enum class profile_av1_e : int {
      main = 1,  ///< Main profile
      high = 2,  ///< High profile
    };

  }  // namespace qsv

  util::Either<avcodec_buffer_t, int> dxgi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);
  util::Either<avcodec_buffer_t, int> vaapi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);
  util::Either<avcodec_buffer_t, int> cuda_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);
  util::Either<avcodec_buffer_t, int> vt_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);

  class avcodec_software_encode_device_t: public platf::avcodec_encode_device_t {
  public:
    int convert(platf::img_t &img) override {
      // If we need to add aspect ratio padding, we need to scale into an intermediate output buffer
      bool requires_padding = (sw_frame->width != sws_output_frame->width || sw_frame->height != sws_output_frame->height);

      // Setup the input frame using the caller's img_t
      sws_input_frame->data[0] = img.data;
      sws_input_frame->linesize[0] = img.row_pitch;

      // Perform color conversion and scaling to the final size
      auto status = sws_scale_frame(sws.get(), requires_padding ? sws_output_frame.get() : sw_frame.get(), sws_input_frame.get());
      if (status < 0) {
        char string[AV_ERROR_MAX_STRING_SIZE];
        BOOST_LOG(error) << "Couldn't scale frame: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
        return -1;
      }

      // If we require aspect ratio padding, copy the output frame into the final padded frame
      if (requires_padding) {
        auto fmt_desc = av_pix_fmt_desc_get((AVPixelFormat) sws_output_frame->format);
        auto planes = av_pix_fmt_count_planes((AVPixelFormat) sws_output_frame->format);
        for (int plane = 0; plane < planes; plane++) {
          auto shift_h = plane == 0 ? 0 : fmt_desc->log2_chroma_h;
          auto shift_w = plane == 0 ? 0 : fmt_desc->log2_chroma_w;
          auto offset = ((offsetW >> shift_w) * fmt_desc->comp[plane].step) + (offsetH >> shift_h) * sw_frame->linesize[plane];

          // Copy line-by-line to preserve leading padding for each row
          for (int line = 0; line < sws_output_frame->height >> shift_h; line++) {
            memcpy(sw_frame->data[plane] + offset + (line * sw_frame->linesize[plane]), sws_output_frame->data[plane] + (line * sws_output_frame->linesize[plane]), (size_t) (sws_output_frame->width >> shift_w) * fmt_desc->comp[plane].step);
          }
        }
      }

      // If frame is not a software frame, it means we still need to transfer from main memory
      // to vram memory
      if (frame->hw_frames_ctx) {
        auto status = av_hwframe_transfer_data(frame, sw_frame.get(), 0);
        if (status < 0) {
          char string[AV_ERROR_MAX_STRING_SIZE];
          BOOST_LOG(error) << "Failed to transfer image data to hardware frame: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
          return -1;
        }
      }

      return 0;
    }

    int set_frame(AVFrame *frame, AVBufferRef *hw_frames_ctx) override {
      this->frame = frame;

      // If it's a hwframe, allocate buffers for hardware
      if (hw_frames_ctx) {
        hw_frame.reset(frame);

        if (av_hwframe_get_buffer(hw_frames_ctx, frame, 0)) {
          return -1;
        }
      } else {
        sw_frame.reset(frame);
      }

      return 0;
    }

    void apply_colorspace() override {
      auto avcodec_colorspace = avcodec_colorspace_from_sunshine_colorspace(colorspace);
      sws_setColorspaceDetails(sws.get(), sws_getCoefficients(SWS_CS_DEFAULT), 0, sws_getCoefficients(avcodec_colorspace.software_format), avcodec_colorspace.range - 1, 0, 1 << 16, 1 << 16);
    }

    /**
     * When preserving aspect ratio, ensure that padding is black
     */
    void prefill() {
      auto frame = sw_frame ? sw_frame.get() : this->frame;
      av_frame_get_buffer(frame, 0);
      av_frame_make_writable(frame);
      ptrdiff_t linesize[4] = {frame->linesize[0], frame->linesize[1], frame->linesize[2], frame->linesize[3]};
      av_image_fill_black(frame->data, linesize, (AVPixelFormat) frame->format, frame->color_range, frame->width, frame->height);
    }

    int init(int in_width, int in_height, AVFrame *frame, AVPixelFormat format, bool hardware) {
      // If the device used is hardware, yet the image resides on main memory
      if (hardware) {
        sw_frame.reset(av_frame_alloc());

        sw_frame->width = frame->width;
        sw_frame->height = frame->height;
        sw_frame->format = format;
      } else {
        this->frame = frame;
      }

      // Fill aspect ratio padding in the destination frame
      prefill();

      auto out_width = frame->width;
      auto out_height = frame->height;

      // Ensure aspect ratio is maintained
      auto scalar = std::fminf((float) out_width / in_width, (float) out_height / in_height);
      out_width = in_width * scalar;
      out_height = in_height * scalar;

      sws_input_frame.reset(av_frame_alloc());
      sws_input_frame->width = in_width;
      sws_input_frame->height = in_height;
      sws_input_frame->format = AV_PIX_FMT_BGR0;

      sws_output_frame.reset(av_frame_alloc());
      sws_output_frame->width = out_width;
      sws_output_frame->height = out_height;
      sws_output_frame->format = format;

      // Result is always positive
      offsetW = (frame->width - out_width) / 2;
      offsetH = (frame->height - out_height) / 2;

      sws.reset(sws_alloc_context());
      if (!sws) {
        return -1;
      }

      AVDictionary *options {nullptr};
      av_dict_set_int(&options, "srcw", sws_input_frame->width, 0);
      av_dict_set_int(&options, "srch", sws_input_frame->height, 0);
      av_dict_set_int(&options, "src_format", sws_input_frame->format, 0);
      av_dict_set_int(&options, "dstw", sws_output_frame->width, 0);
      av_dict_set_int(&options, "dsth", sws_output_frame->height, 0);
      av_dict_set_int(&options, "dst_format", sws_output_frame->format, 0);
      av_dict_set_int(&options, "sws_flags", SWS_LANCZOS | SWS_ACCURATE_RND, 0);
      av_dict_set_int(&options, "threads", config::video.min_threads, 0);

      auto status = av_opt_set_dict(sws.get(), &options);
      av_dict_free(&options);
      if (status < 0) {
        char string[AV_ERROR_MAX_STRING_SIZE];
        BOOST_LOG(error) << "Failed to set SWS options: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
        return -1;
      }

      status = sws_init_context(sws.get(), nullptr, nullptr);
      if (status < 0) {
        char string[AV_ERROR_MAX_STRING_SIZE];
        BOOST_LOG(error) << "Failed to initialize SWS: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
        return -1;
      }

      return 0;
    }

    // Store ownership when frame is hw_frame
    avcodec_frame_t hw_frame;

    avcodec_frame_t sw_frame;
    avcodec_frame_t sws_input_frame;
    avcodec_frame_t sws_output_frame;
    sws_t sws;

    // Offset of input image to output frame in pixels
    int offsetW;
    int offsetH;
  };

  enum flag_e : uint32_t {
    DEFAULT = 0,  ///< Default flags
    PARALLEL_ENCODING = 1 << 1,  ///< Capture and encoding can run concurrently on separate threads
    H264_ONLY = 1 << 2,  ///< When HEVC is too heavy
    LIMITED_GOP_SIZE = 1 << 3,  ///< Some encoders don't like it when you have an infinite GOP_SIZE. e.g. VAAPI
    SINGLE_SLICE_ONLY = 1 << 4,  ///< Never use multiple slices. Older intel iGPU's ruin it for everyone else
    CBR_WITH_VBR = 1 << 5,  ///< Use a VBR rate control mode to simulate CBR
    RELAXED_COMPLIANCE = 1 << 6,  ///< Use FF_COMPLIANCE_UNOFFICIAL compliance mode
    NO_RC_BUF_LIMIT = 1 << 7,  ///< Don't set rc_buffer_size
    REF_FRAMES_INVALIDATION = 1 << 8,  ///< Support reference frames invalidation
    ALWAYS_REPROBE = 1 << 9,  ///< This is an encoder of last resort and we want to aggressively probe for a better one
    YUV444_SUPPORT = 1 << 10,  ///< Encoder may support 4:4:4 chroma sampling depending on hardware
    ASYNC_TEARDOWN = 1 << 11,  ///< Encoder supports async teardown on a different thread
    FIXED_GOP_SIZE = 1 << 12,  ///< Use fixed small GOP size (encoder doesn't support on-demand IDR frames)
  };

  class avcodec_encode_session_t: public encode_session_t {
  public:
    avcodec_encode_session_t() = default;

    avcodec_encode_session_t(avcodec_ctx_t &&avcodec_ctx, std::unique_ptr<platf::avcodec_encode_device_t> encode_device, int inject):
        avcodec_ctx {std::move(avcodec_ctx)},
        device {std::move(encode_device)},
        inject {inject} {
    }

    avcodec_encode_session_t(avcodec_encode_session_t &&other) noexcept = default;

    ~avcodec_encode_session_t() {
      // Flush any remaining frames in the encoder if the encoder started up (frame num > 0)
      if (avcodec_ctx->frame_num > 0 && avcodec_send_frame(avcodec_ctx.get(), nullptr) == 0) {
        packet_raw_avcodec pkt;
        while (avcodec_receive_packet(avcodec_ctx.get(), pkt.av_packet) == 0);
      }

      // Order matters here because the context relies on the hwdevice still being valid
      avcodec_ctx.reset();
      device.reset();
    }

    // Ensure objects are destroyed in the correct order
    avcodec_encode_session_t &operator=(avcodec_encode_session_t &&other) {
      device = std::move(other.device);
      avcodec_ctx = std::move(other.avcodec_ctx);
      replacements = std::move(other.replacements);
      channel_owner = std::move(other.channel_owner);
      frame_timestamps = std::move(other.frame_timestamps);
      sps = std::move(other.sps);
      vps = std::move(other.vps);

      inject = other.inject;

      return *this;
    }

    int convert(platf::img_t &img) override {
      if (!device) {
        return -1;
      }
      return device->convert(img);
    }

    // Hot-set on the running encoder where it can, so a bitrate change costs nothing.
    bool set_bitrate(int kbps) override {
      return avcodec_ctx && av_opt_set_int(avcodec_ctx->priv_data, "live_bitrate", std::int64_t(kbps) * 1000, 0) >= 0;
    }

    void request_idr_frame() override {
      if (device && device->frame) {
        auto &frame = device->frame;
        frame->pict_type = AV_PICTURE_TYPE_I;
        frame->flags |= AV_FRAME_FLAG_KEY;
      }
    }

    void request_normal_frame() override {
      if (device && device->frame) {
        auto &frame = device->frame;
        frame->pict_type = AV_PICTURE_TYPE_NONE;
        frame->flags &= ~AV_FRAME_FLAG_KEY;
      }
    }

    void invalidate_ref_frames(int64_t first_frame, int64_t last_frame) override {
      BOOST_LOG(error) << "Encoder doesn't support reference frame invalidation";
      request_idr_frame();
    }

    avcodec_ctx_t avcodec_ctx;
    std::unique_ptr<platf::avcodec_encode_device_t> device;

    std::shared_ptr<const std::vector<packet_raw_t::replace_t>> replacements;
    std::map<int64_t, std::optional<std::chrono::steady_clock::time_point>> frame_timestamps;

    cbs::nal_t sps;
    cbs::nal_t vps;

    // inject sps/vps data into idr pictures
    int inject;
  };

#ifndef __APPLE__
  // NVENC is unreachable on macOS and nvenc_base.cpp is not compiled there; without this
  // gate the class's vtable emission leaves undefined nvenc:: symbols at link time.
  class nvenc_encode_session_t: public encode_session_t {
  public:
    nvenc_encode_session_t(std::unique_ptr<platf::nvenc_encode_device_t> encode_device):
        device(std::move(encode_device)) {
    }

    int convert(platf::img_t &img) override {
      if (!device) {
        return -1;
      }
      return device->convert(img);
    }

    void request_idr_frame() override {
      force_idr = true;
    }

    void request_normal_frame() override {
      force_idr = false;
    }

    void invalidate_ref_frames(int64_t first_frame, int64_t last_frame) override {
      if (!device || !device->nvenc) {
        return;
      }

      if (!device->nvenc->invalidate_ref_frames(first_frame, last_frame)) {
        force_idr = true;
      }
    }

    nvenc::nvenc_encoded_frame encode_frame(uint64_t frame_index) {
      if (!device || !device->nvenc) {
        return {};
      }

      auto result = device->nvenc->encode_frame(frame_index, force_idr);
      force_idr = false;
      return result;
    }

  private:
    std::unique_ptr<platf::nvenc_encode_device_t> device;
    bool force_idr = false;
  };
#endif

  struct sync_session_ctx_t {
    safe::signal_t *join_event;
    safe::mail_raw_t::event_t<bool> shutdown_event;
    safe::mail_raw_t::queue_t<packet_t> packets;
    safe::mail_raw_t::event_t<bool> idr_events;
    safe::mail_raw_t::event_t<hdr_info_t> hdr_events;
    safe::mail_raw_t::event_t<input::touch_port_t> touch_port_events;

    config_t config;
    int frame_nr;
    void *channel_data;
  };

  struct sync_session_t {
    sync_session_ctx_t *ctx;
    std::unique_ptr<encode_session_t> session;
  };

  using encode_session_ctx_queue_t = safe::queue_t<sync_session_ctx_t>;
  using encode_e = platf::capture_e;

  struct capture_ctx_t {
    img_event_t images;
    config_t config;
  };

  struct capture_thread_async_ctx_t {
    std::shared_ptr<safe::queue_t<capture_ctx_t>> capture_ctx_queue;
    std::thread capture_thread;

    safe::signal_t reinit_event;
    const encoder_t *encoder_p;
    sync_util::sync_t<std::weak_ptr<platf::display_t>> display_wp;
  };

  struct capture_thread_sync_ctx_t {
    encode_session_ctx_queue_t encode_session_ctx_queue {30};
  };

  int start_capture_sync(capture_thread_sync_ctx_t &ctx);
  void end_capture_sync(capture_thread_sync_ctx_t &ctx);
  int start_capture_async(capture_thread_async_ctx_t &ctx);
  void end_capture_async(capture_thread_async_ctx_t &ctx);

  // Keep a reference counter to ensure the capture thread only runs when other threads have a reference to the capture thread
  auto capture_thread_async = safe::make_shared<capture_thread_async_ctx_t>(start_capture_async, end_capture_async);
  auto capture_thread_sync = safe::make_shared<capture_thread_sync_ctx_t>(start_capture_sync, end_capture_sync);

#ifdef _WIN32
  encoder_t nvenc {
    "nvenc"sv,
    std::make_unique<encoder_platform_formats_nvenc>(
      platf::mem_type_e::dxgi,
      platf::pix_fmt_e::nv12,
      platf::pix_fmt_e::p010,
      platf::pix_fmt_e::ayuv,
      platf::pix_fmt_e::yuv444p16
    ),
    {
      {},  // Common options
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_nvenc"s,
    },
    {
      {},  // Common options
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_nvenc"s,
    },
    {
      {},  // Common options
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_nvenc"s,
    },
    PARALLEL_ENCODING | REF_FRAMES_INVALIDATION | YUV444_SUPPORT | ASYNC_TEARDOWN  // flags
  };
#elif !defined(__APPLE__)
  encoder_t nvenc {
    "nvenc"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
  #ifdef _WIN32
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_D3D11,
  #else
      AV_HWDEVICE_TYPE_CUDA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_CUDA,
  #endif
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
  #ifdef _WIN32
      dxgi_init_avcodec_hardware_input_buffer
  #else
      cuda_init_avcodec_hardware_input_buffer
  #endif
    ),
    {
      // Common options
      {
        {"delay"s, 0},
        {"forced-idr"s, 1},
        {"zerolatency"s, 1},
        {"surfaces"s, 1},
        {"cbr_padding"s, false},
        {"preset"s, &config::video.nv_legacy.preset},
        {"tune"s, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY},
        {"rc"s, NV_ENC_PARAMS_RC_CBR},
        {"multipass"s, &config::video.nv_legacy.multipass},
        {"aq"s, &config::video.nv_legacy.aq},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_nvenc"s,
    },
    {
      // Common options
      {
        {"delay"s, 0},
        {"forced-idr"s, 1},
        {"zerolatency"s, 1},
        {"surfaces"s, 1},
        {"cbr_padding"s, false},
        {"preset"s, &config::video.nv_legacy.preset},
        {"tune"s, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY},
        {"rc"s, NV_ENC_PARAMS_RC_CBR},
        {"multipass"s, &config::video.nv_legacy.multipass},
        {"aq"s, &config::video.nv_legacy.aq},
      },
      {
        // SDR-specific options
        {"profile"s, (int) nv::profile_hevc_e::main},
      },
      {
        // HDR-specific options
        {"profile"s, (int) nv::profile_hevc_e::main_10},
      },
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_nvenc"s,
    },
    {
      {
        {"delay"s, 0},
        {"forced-idr"s, 1},
        {"zerolatency"s, 1},
        {"surfaces"s, 1},
        {"cbr_padding"s, false},
        {"preset"s, &config::video.nv_legacy.preset},
        {"tune"s, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY},
        {"rc"s, NV_ENC_PARAMS_RC_CBR},
        {"coder"s, &config::video.nv_legacy.h264_coder},
        {"multipass"s, &config::video.nv_legacy.multipass},
        {"aq"s, &config::video.nv_legacy.aq},
      },
      {
        // SDR-specific options
        {"profile"s, (int) nv::profile_h264_e::high},
      },
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_nvenc"s,
    },
    PARALLEL_ENCODING
  };
#endif

#ifdef _WIN32
  encoder_t quicksync {
    "quicksync"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_QSV,
      AV_PIX_FMT_QSV,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_VUYX,
      AV_PIX_FMT_XV30,
      dxgi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"preset"s, &config::video.qsv.qsv_preset},
        {"forced_idr"s, 1},
        {"async_depth"s, 1},
        {"low_delay_brc"s, 1},
        {"low_power"s, 1},
      },
      {
        // SDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::main},
      },
      {
        // HDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::main},
      },
      {
        // YUV444 SDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::high},
      },
      {
        // YUV444 HDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::high},
      },
      {},  // Fallback options
      "av1_qsv"s,
    },
    {
      // Common options
      {
        {"preset"s, &config::video.qsv.qsv_preset},
        {"forced_idr"s, 1},
        {"async_depth"s, 1},
        {"low_delay_brc"s, 1},
        {"low_power"s, 1},
        {"recovery_point_sei"s, 0},
        {"pic_timing_sei"s, 0},
      },
      {
        // SDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::main},
      },
      {
        // HDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::main_10},
      },
      {
        // YUV444 SDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::rext},
      },
      {
        // YUV444 HDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::rext},
      },
      {
        // Fallback options
        {"low_power"s, []() {
           return config::video.qsv.qsv_slow_hevc ? 0 : 1;
         }},
      },
      "hevc_qsv"s,
    },
    {
      // Common options
      {
        {"preset"s, &config::video.qsv.qsv_preset},
        {"cavlc"s, &config::video.qsv.qsv_cavlc},
        {"forced_idr"s, 1},
        {"async_depth"s, 1},
        {"low_delay_brc"s, 1},
        {"low_power"s, 1},
        {"recovery_point_sei"s, 0},
        {"vcm"s, 1},
        {"pic_timing_sei"s, 0},
        {"max_dec_frame_buffering"s, 1},
      },
      {
        // SDR-specific options
        {"profile"s, (int) qsv::profile_h264_e::high},
      },
      {},  // HDR-specific options
      {
        // YUV444 SDR-specific options
        {"profile"s, (int) qsv::profile_h264_e::high_444p},
      },
      {},  // YUV444 HDR-specific options
      {
        // Fallback options
        {"low_power"s, 0},  // Some old/low-end Intel GPUs don't support low power encoding
      },
      "h264_qsv"s,
    },
    PARALLEL_ENCODING | CBR_WITH_VBR | RELAXED_COMPLIANCE | NO_RC_BUF_LIMIT | YUV444_SUPPORT
  };

  encoder_t amdvce {
    "amdvce"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_D3D11,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
      dxgi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"filler_data"s, false},
        {"forced_idr"s, 1},
        {"latency"s, "lowest_latency"s},
        {"async_depth"s, 1},
        {"skip_frame"s, 0},
        {"log_to_dbg"s, []() {
           return config::sunshine.min_log_level < 2 ? 1 : 0;
         }},
        {"preencode"s, &config::video.amd.amd_preanalysis},
        {"quality"s, &config::video.amd.amd_quality_av1},
        {"rc"s, &config::video.amd.amd_rc_av1},
        {"usage"s, &config::video.amd.amd_usage_av1},
        {"enforce_hrd"s, &config::video.amd.amd_enforce_hrd},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_amf"s,
    },
    {
      // Common options
      {
        {"filler_data"s, false},
        {"forced_idr"s, 1},
        {"latency"s, 1},
        {"async_depth"s, 1},
        {"skip_frame"s, 0},
        {"log_to_dbg"s, []() {
           return config::sunshine.min_log_level < 2 ? 1 : 0;
         }},
        {"gops_per_idr"s, 1},
        {"header_insertion_mode"s, "idr"s},
        {"preencode"s, &config::video.amd.amd_preanalysis},
        {"quality"s, &config::video.amd.amd_quality_hevc},
        {"rc"s, &config::video.amd.amd_rc_hevc},
        {"usage"s, &config::video.amd.amd_usage_hevc},
        {"vbaq"s, &config::video.amd.amd_vbaq},
        {"enforce_hrd"s, &config::video.amd.amd_enforce_hrd},
        {"level"s, [](const config_t &cfg) {
           auto size = cfg.width * cfg.height;
           // For 4K and below, try to use level 5.1 or 5.2 if possible
           if (size <= 8912896) {
             if (size * cfg.framerate <= 534773760) {
               return "5.1"s;
             } else if (size * cfg.framerate <= 1069547520) {
               return "5.2"s;
             }
           }
           return "auto"s;
         }},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_amf"s,
    },
    {
      // Common options
      {
        {"filler_data"s, false},
        {"forced_idr"s, 1},
        {"latency"s, 1},
        {"async_depth"s, 1},
        {"frame_skipping"s, 0},
        {"log_to_dbg"s, []() {
           return config::sunshine.min_log_level < 2 ? 1 : 0;
         }},
        {"preencode"s, &config::video.amd.amd_preanalysis},
        {"quality"s, &config::video.amd.amd_quality_h264},
        {"rc"s, &config::video.amd.amd_rc_h264},
        {"usage"s, &config::video.amd.amd_usage_h264},
        {"vbaq"s, &config::video.amd.amd_vbaq},
        {"enforce_hrd"s, &config::video.amd.amd_enforce_hrd},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {
        // Fallback options
        {"usage"s, 2 /* AMF_VIDEO_ENCODER_USAGE_LOW_LATENCY */},  // Workaround for https://github.com/GPUOpen-LibrariesAndSDKs/AMF/issues/410
      },
      "h264_amf"s,
    },
    PARALLEL_ENCODING
  };

  encoder_t mediafoundation {
    "mediafoundation"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_D3D11,
      AV_PIX_FMT_NV12,  // SDR 4:2:0 8-bit (only format Qualcomm supports)
      AV_PIX_FMT_NONE,  // No HDR - Qualcomm MF only supports 8-bit
      AV_PIX_FMT_NONE,  // No YUV444 SDR
      AV_PIX_FMT_NONE,  // No YUV444 HDR
      dxgi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options for AV1 - Qualcomm MF encoder
      {
        {"hw_encoding"s, 1},
        {"rate_control"s, "cbr"s},
        {"scenario"s, "display_remoting"s},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_mf"s,
    },
    {
      // Common options for HEVC - Qualcomm MF encoder
      {
        {"hw_encoding"s, 1},
        {"rate_control"s, "cbr"s},
        {"scenario"s, "display_remoting"s},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_mf"s,
    },
    {
      // Common options for H.264 - Qualcomm MF encoder
      {
        {"hw_encoding"s, 1},
        {"rate_control"s, "cbr"s},
        {"scenario"s, "display_remoting"s},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_mf"s,
    },
    PARALLEL_ENCODING | FIXED_GOP_SIZE  // MF encoder doesn't support on-demand IDR frames
  };
#endif

  encoder_t software {
    "software"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_NONE,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_YUV420P,
      AV_PIX_FMT_YUV420P10,
      AV_PIX_FMT_YUV444P,
      AV_PIX_FMT_YUV444P10,
      nullptr
    ),
    {
      // libsvtav1 takes different presets than libx264/libx265.
      // We set an infinite GOP length, use a low delay prediction structure,
      // force I frames to be key frames, and set max bitrate to default to work
      // around a FFmpeg bug with CBR mode.
      {
        {"svtav1-params"s, "keyint=-1:pred-struct=1:force-key-frames=1:mbr=0"s},
        {"preset"s, &config::video.sw.svtav1_preset},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options

#ifdef ENABLE_BROKEN_AV1_ENCODER
           // Due to bugs preventing on-demand IDR frames from working and very poor
           // real-time encoding performance, we do not enable libsvtav1 by default.
           // It is only suitable for testing AV1 until the IDR frame issue is fixed.
      "libsvtav1"s,
#else
      {},
#endif
    },
    {
      // x265's Info SEI is so long that it causes the IDR picture data to be
      // kicked to the 2nd packet in the frame, breaking Moonlight's parsing logic.
      // It also looks like gop_size isn't passed on to x265, so we have to set
      // 'keyint=-1' in the parameters ourselves.
      {
        {"forced-idr"s, 1},
        {"x265-params"s, "info=0:keyint=-1"s},
        {"preset"s, &config::video.sw.sw_preset},
        {"tune"s, &config::video.sw.sw_tune},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "libx265"s,
    },
    {
      // Common options
      {
        {"preset"s, &config::video.sw.sw_preset},
        {"tune"s, &config::video.sw.sw_tune},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "libx264"s,
    },
    H264_ONLY | PARALLEL_ENCODING | ALWAYS_REPROBE | YUV444_SUPPORT
  };

#if defined(__linux__) || defined(linux) || defined(__linux) || defined(__FreeBSD__)
  encoder_t vaapi {
    "vaapi"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_VAAPI,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_VAAPI,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
      vaapi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"async_depth"s, 1},
        {"idr_interval"s, std::numeric_limits<int>::max()},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_vaapi"s,
    },
    {
      // Common options
      {
        {"async_depth"s, 1},
        {"sei"s, 0},
        {"idr_interval"s, std::numeric_limits<int>::max()},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_vaapi"s,
    },
    {
      // Common options
      {
        {"async_depth"s, 1},
        {"sei"s, 0},
        {"idr_interval"s, std::numeric_limits<int>::max()},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_vaapi"s,
    },
    // RC buffer size will be set in platform code if supported
    LIMITED_GOP_SIZE | PARALLEL_ENCODING | NO_RC_BUF_LIMIT
  };
#endif

#ifdef __APPLE__
  encoder_t videotoolbox {
    "videotoolbox"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_VIDEOTOOLBOX,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
      vt_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"allow_sw"s, &config::video.vt.vt_allow_sw},
        {"require_sw"s, &config::video.vt.vt_require_sw},
        {"realtime"s, &config::video.vt.vt_realtime},
        {"prio_speed"s, 1},
        {"power_efficient"s, 0},  // Apple recommends power-efficient mode OFF for latency-critical encoding; don't leave it at implicit default.
        {"max_ref_frames"s, 1},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_videotoolbox"s,
    },
    {
      // Common options
      {
        {"allow_sw"s, &config::video.vt.vt_allow_sw},
        {"require_sw"s, &config::video.vt.vt_require_sw},
        {"realtime"s, &config::video.vt.vt_realtime},
        {"prio_speed"s, 1},
        {"power_efficient"s, 0},  // Apple recommends power-efficient mode OFF for latency-critical encoding; don't leave it at implicit default.
        {"max_ref_frames"s, 1},
        {"constant_bit_rate"s, &config::video.vt.vt_cbr},  // default 0 (off), byte-identical to pre-experiment behavior
        {"sync_output"s, &config::video.vt.vt_sync_output},  // default 1 on macOS; the release build requires patched FFmpeg;
                                                              // requires the locally-patched ffmpeg
                                                              // (patches/ffmpeg-vtenc-sync-output.patch) to have any
                                                              // effect. On stock ffmpeg the unknown AVOption is left
                                                              // unconsumed (non-fatal, logged by lavc) -- verified.
                                                              // When 1 on patched ffmpeg: send_frame blocks ~10.5ms
                                                              // until the submitted frame's own packet returns,
                                                              // taking enc_age from 2-3 frames to 0.
        {"sync_deadline_us"s, &config::video.vt.vt_sync_deadline_us},  // default 14000 (14ms); only meaningful
                                                              // when sync_output=1 on the patched ffmpeg (same
                                                              // stock-ffmpeg unknown-option tolerance as sync_output
                                                              // above). Bounds the sync_output blocking pop so an
                                                              // encode-latency spike degrades to "collect this
                                                              // frame's packet next call" instead of stalling the
                                                              // capture loop past its frame budget.
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_videotoolbox"s,
    },
    {
      // Common options
      // Note: max_ref_frames is intentionally omitted for H.264 because
      // VideoToolbox on Apple Silicon produces all-IDR output when
      // ReferenceBufferCount=1 is set for H.264, causing massive frame drops.
      // HEVC is unaffected and retains max_ref_frames=1.
      {
        {"allow_sw"s, &config::video.vt.vt_allow_sw},
        {"require_sw"s, &config::video.vt.vt_require_sw},
        {"realtime"s, &config::video.vt.vt_realtime},
        {"prio_speed"s, 1},
        {"power_efficient"s, 0},  // Apple recommends power-efficient mode OFF for latency-critical encoding; don't leave it at implicit default.
        {"constant_bit_rate"s, &config::video.vt.vt_cbr},  // default 0 (off), byte-identical to pre-experiment behavior
        {"sync_output"s, &config::video.vt.vt_sync_output},  // default 1 on macOS; the release build requires patched FFmpeg;
                                                              // requires the locally-patched ffmpeg
                                                              // (patches/ffmpeg-vtenc-sync-output.patch) to have any
                                                              // effect. On stock ffmpeg the unknown AVOption is left
                                                              // unconsumed (non-fatal, logged by lavc) -- verified.
                                                              // When 1 on patched ffmpeg: send_frame blocks ~10.5ms
                                                              // until the submitted frame's own packet returns,
                                                              // taking enc_age from 2-3 frames to 0.
        {"sync_deadline_us"s, &config::video.vt.vt_sync_deadline_us},  // default 14000 (14ms); only meaningful
                                                              // when sync_output=1 on the patched ffmpeg (same
                                                              // stock-ffmpeg unknown-option tolerance as sync_output
                                                              // above). Bounds the sync_output blocking pop so an
                                                              // encode-latency spike degrades to "collect this
                                                              // frame's packet next call" instead of stalling the
                                                              // capture loop past its frame budget.
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_videotoolbox"s,
    },
    // FIXED_GOP_SIZE was removed 2026-07-10: on-demand IDR is proven working with the
    // bundled lavc 62 (pict_type=I + AV_FRAME_FLAG_KEY lands exactly on request — see
    // tests/unit/test_videotoolbox.cpp OnDemandIdrHonored and the live IDR-request log
    // evidence). The old ~2s fixed GOP emitted a giant IDR every 120 frames, which was
    // a metronomic bitrate burst = visible periodic stutter at high resolutions.
    // Historical note: the original "VT ignores IDR requests / one keyframe ever" claim
    // predated the LOW_DELAY fix below; with LOW_DELAY stripped, request_idr_frame works.
    PARALLEL_ENCODING
  };
#endif

  static const std::vector<encoder_t *> encoders {
#ifndef __APPLE__
    &nvenc,
#endif
#ifdef _WIN32
    &quicksync,
    &amdvce,
    &mediafoundation,
#endif
#if defined(__linux__) || defined(linux) || defined(__linux) || defined(__FreeBSD__)
    &vaapi,
#endif
#ifdef __APPLE__
    &videotoolbox,
#endif
    &software
  };

  static encoder_t *chosen_encoder;
  int active_hevc_mode;
  int active_av1_mode;
  bool last_encoder_probe_supported_ref_frames_invalidation = false;
  std::array<bool, 3> last_encoder_probe_supported_yuv444_for_codec = {};

  void reset_display(std::shared_ptr<platf::display_t> &disp, const platf::mem_type_e &type, const std::string &display_name, const config_t &config) {
    // We try this twice, in case we still get an error on reinitialization
    for (int x = 0; x < 2; ++x) {
      disp.reset();
      disp = platf::display(type, display_name, config);
      if (disp) {
        break;
      }

      // The capture code depends on us to sleep between failures
      std::this_thread::sleep_for(200ms);
    }
  }

  /**
   * @brief Update the list of display names before or during a stream.
   * @details This will attempt to keep `current_display_index` pointing at the same display.
   * @param dev_type The encoder device type used for display lookup.
   * @param display_names The list of display names to repopulate.
   * @param current_display_index The current display index or -1 if not yet known.
   */
  void refresh_displays(platf::mem_type_e dev_type, std::vector<std::string> &display_names, int &current_display_index) {
    // It is possible that the output name may be empty even if it wasn't before (device disconnected) or vice-versa
    const auto output_name {display_device::map_output_name(config::video.output_name)};
    std::string current_display_name;

    // If we have a current display index, let's start with that
    if (current_display_index >= 0 && current_display_index < display_names.size()) {
      current_display_name = display_names.at(current_display_index);
    }

    // Refresh the display names
    auto old_display_names = std::move(display_names);
    display_names = platf::display_names(dev_type);

    // If we now have no displays, let's put the old display array back and fail
    if (display_names.empty() && !old_display_names.empty()) {
      BOOST_LOG(error) << "No displays were found after reenumeration!"sv;
      display_names = std::move(old_display_names);
      return;
    } else if (display_names.empty()) {
      display_names.emplace_back(output_name);
    }

    // We now have a new display name list, so reset the index back to 0
    current_display_index = 0;

    // If we had a name previously, let's try to find it in the new list
    if (!current_display_name.empty()) {
      for (int x = 0; x < display_names.size(); ++x) {
        if (display_names[x] == current_display_name) {
          current_display_index = x;
          return;
        }
      }

      // The old display was removed, so we'll start back at the first display again
      BOOST_LOG(warning) << "Previous active display ["sv << current_display_name << "] is no longer present"sv;
    } else {
      for (int x = 0; x < display_names.size(); ++x) {
        if (display_names[x] == output_name) {
          current_display_index = x;
          return;
        }
      }
    }
  }

  void captureThread(
    std::shared_ptr<safe::queue_t<capture_ctx_t>> capture_ctx_queue,
    sync_util::sync_t<std::weak_ptr<platf::display_t>> &display_wp,
    safe::signal_t &reinit_event,
    const encoder_t &encoder
  ) {
    try {
      std::vector<capture_ctx_t> capture_ctxs;

      auto fg = util::fail_guard([&]() {
        capture_ctx_queue->stop();

        // Stop all sessions listening to this thread
        for (auto &capture_ctx : capture_ctxs) {
          capture_ctx.images->stop();
        }
        for (auto &capture_ctx : capture_ctx_queue->unsafe()) {
          capture_ctx.images->stop();
        }
      });

      auto switch_display_event = mail::man->event<int>(mail::switch_display);

      // Wait for the initial capture context or a request to stop the queue
      auto initial_capture_ctx = capture_ctx_queue->pop();
      if (!initial_capture_ctx) {
        return;
      }
      capture_ctxs.emplace_back(std::move(*initial_capture_ctx));

      // Get all the monitor names now, rather than at boot, to
      // get the most up-to-date list available monitors
      std::vector<std::string> display_names;
      int display_p = -1;
      refresh_displays(encoder.platform_formats->dev_type, display_names, display_p);
      auto disp = platf::display(encoder.platform_formats->dev_type, display_names[display_p], capture_ctxs.front().config);
      if (!disp) {
        return;
      }
      display_wp = disp;

      constexpr auto capture_buffer_size = 12;
      std::list<std::shared_ptr<platf::img_t>> imgs(capture_buffer_size);

      std::vector<std::optional<std::chrono::steady_clock::time_point>> imgs_used_timestamps;
      const std::chrono::seconds trim_timeot = 3s;
      auto trim_imgs = [&]() {
        // count allocated and used within current pool
        size_t allocated_count = 0;
        size_t used_count = 0;
        for (const auto &img : imgs) {
          if (img) {
            allocated_count += 1;
            if (img.use_count() > 1) {
              used_count += 1;
            }
          }
        }

        // remember the timestamp of currently used count
        const auto now = std::chrono::steady_clock::now();
        if (imgs_used_timestamps.size() <= used_count) {
          imgs_used_timestamps.resize(used_count + 1);
        }
        imgs_used_timestamps[used_count] = now;

        // decide whether to trim allocated unused above the currently used count
        // based on last used timestamp and universal timeout
        size_t trim_target = used_count;
        for (size_t i = used_count; i < imgs_used_timestamps.size(); i++) {
          if (imgs_used_timestamps[i] && now - *imgs_used_timestamps[i] < trim_timeot) {
            trim_target = i;
          }
        }

        // trim allocated unused above the newly decided trim target
        if (allocated_count > trim_target) {
          size_t to_trim = allocated_count - trim_target;
          // prioritize trimming least recently used
          for (auto it = imgs.rbegin(); it != imgs.rend(); it++) {
            auto &img = *it;
            if (img && img.use_count() == 1) {
              img.reset();
              to_trim -= 1;
              if (to_trim == 0) {
                break;
              }
            }
          }
          // forget timestamps that no longer relevant
          imgs_used_timestamps.resize(trim_target + 1);
        }
      };

      auto pull_free_image_callback = [&](std::shared_ptr<platf::img_t> &img_out) -> bool {
        img_out.reset();
        while (capture_ctx_queue->running()) {
          // pick first allocated but unused
          for (auto it = imgs.begin(); it != imgs.end(); it++) {
            if (*it && it->use_count() == 1) {
              img_out = *it;
              if (it != imgs.begin()) {
                // move image to the front of the list to prioritize its reusal
                imgs.erase(it);
                imgs.push_front(img_out);
              }
              break;
            }
          }
          // otherwise pick first unallocated
          if (!img_out) {
            for (auto it = imgs.begin(); it != imgs.end(); it++) {
              if (!*it) {
                // allocate image
                *it = disp->alloc_img();
                img_out = *it;
                if (it != imgs.begin()) {
                  // move image to the front of the list to prioritize its reusal
                  imgs.erase(it);
                  imgs.push_front(img_out);
                }
                break;
              }
            }
          }
          if (img_out) {
            // trim allocated but unused portion of the pool based on timeouts
            trim_imgs();
            img_out->frame_timestamp.reset();
            return true;
          } else {
            // sleep and retry if image pool is full
            std::this_thread::sleep_for(1ms);
          }
        }
        return false;
      };

      // Capture takes place on this thread
      platf::set_thread_name("video::capture");
      platf::adjust_thread_priority(platf::thread_priority_e::critical);

      platf::macos::capture_recovery_budget recovery_budget;
      while (capture_ctx_queue->running()) {
        bool artificial_reinit = false;

        auto push_captured_image_callback = [&](std::shared_ptr<platf::img_t> &&img, bool frame_captured) -> bool {
          KITTY_WHILE_LOOP(auto capture_ctx = std::begin(capture_ctxs), capture_ctx != std::end(capture_ctxs), {
            if (!capture_ctx->images->running()) {
              capture_ctx = capture_ctxs.erase(capture_ctx);

              continue;
            }

            if (frame_captured) {
              capture_ctx->images->raise(img);
            }

            ++capture_ctx;
          })

          if (!capture_ctx_queue->running()) {
            return false;
          }

          while (capture_ctx_queue->peek()) {
            capture_ctxs.emplace_back(std::move(*capture_ctx_queue->pop()));
          }

          if (switch_display_event->peek()) {
            artificial_reinit = true;
            return false;
          }

          return true;
        };

        // capture() takes its callbacks by value (WS2 capture-teardown UAF fix).
        // push_captured_image_callback is loop-local, safe to move; pull_free_image_callback
        // is defined OUTSIDE the loop and reused on reinit-continue (display switch) -- moving
        // it empties the std::function (captures exceed the SBO) and the next iteration
        // throws bad_function_call, killing the capture thread.
        auto status = disp->capture(std::move(push_captured_image_callback), pull_free_image_callback, &display_cursor);

#ifdef __APPLE__
        const bool runtime_recovery = status == platf::capture_e::reinit && !artificial_reinit;
#else
        const bool runtime_recovery = false;
#endif
        if (runtime_recovery && !recovery_budget.request(std::chrono::steady_clock::now())) {
          BOOST_LOG(error) << "Capture recovery exhausted (3 interruptions in 30 seconds); reconnect after checking the capture source";
          return;
        }

        if (artificial_reinit && status != platf::capture_e::error) {
          status = platf::capture_e::reinit;

          artificial_reinit = false;
        }

        switch (status) {
          case platf::capture_e::reinit:
            {
              reinit_event.raise(true);
              const auto recovery_deadline = std::chrono::steady_clock::now() + 5s;

              // Some classes of images contain references to the display --> display won't delete unless img is deleted
              for (auto &img : imgs) {
                img.reset();
              }

              // display_wp is modified in this thread only
              // Wait for the other shared_ptr's of display to be destroyed.
              // New displays will only be created in this thread.
              while (display_wp->use_count() != 1) {
                if (!capture_ctx_queue->running() || (runtime_recovery && std::chrono::steady_clock::now() >= recovery_deadline)) return;
                // Free images that weren't consumed by the encoders. These can reference the display and prevent
                // the ref count from reaching 1. We do this here rather than on the encoder thread to avoid race
                // conditions where the encoding loop might free a good frame after reinitializing if we capture
                // a new frame here before the encoder has finished reinitializing.
                KITTY_WHILE_LOOP(auto capture_ctx = std::begin(capture_ctxs), capture_ctx != std::end(capture_ctxs), {
                  if (!capture_ctx->images->running()) {
                    capture_ctx = capture_ctxs.erase(capture_ctx);
                    continue;
                  }

                  while (capture_ctx->images->peek()) {
                    capture_ctx->images->pop();
                  }

                  ++capture_ctx;
                });

                std::this_thread::sleep_for(20ms);
              }

              while (capture_ctx_queue->running()) {
                if (runtime_recovery && std::chrono::steady_clock::now() >= recovery_deadline) {
                  BOOST_LOG(error) << "Capture source did not return within the recovery window";
                  return;
                }
                // Release the display before reenumerating displays, since some capture backends
                // only support a single display session per device/application.
                disp.reset();

                // Refresh display names since a display removal might have caused the reinitialization
                refresh_displays(encoder.platform_formats->dev_type, display_names, display_p);

                // Process any pending display switch with the new list of displays
                if (switch_display_event->peek()) {
                  // peek() and pop() are not atomic, so a concurrent stop() can still leave
                  // pop() with nothing to return even though peek() just saw a value.
                  if (auto switch_display = switch_display_event->pop()) {
                    display_p = std::clamp(*switch_display, 0, (int) display_names.size() - 1);
                  }
                }

                // reset_display() will sleep between retries
                reset_display(disp, encoder.platform_formats->dev_type, display_names[display_p], capture_ctxs.front().config);
                if (disp) {
                  break;
                }
              }
              if (!disp) {
                return;
              }

              display_wp = disp;

              reinit_event.reset();
              continue;
            }
          case platf::capture_e::error:
          case platf::capture_e::ok:
          case platf::capture_e::timeout:
          case platf::capture_e::interrupted:
            return;
          default:
            BOOST_LOG(error) << "Unrecognized capture status ["sv << (int) status << ']';
            return;
        }
      }
    } catch (const std::exception &e) {
      BOOST_LOG(fatal) << "captureThread terminating on exception: " << e.what();
      std::abort();
    } catch (...) {
      BOOST_LOG(fatal) << "captureThread terminating on unknown exception";
      std::abort();
    }
  }

  // Encoder-latency instrumentation (perf_trace only; docs/design hunt: hunt-encoder-path.md).
  // Populated inside encode_avcodec() when config::video.perf_trace is set; harmless/ignored
  // when perf_trace is off or the pointer is null, matching the existing out_keyframe_emitted
  // out-param pattern below.
  struct perf_encode_call_stats_t {
    std::int64_t age_max = 0; // max (frame_nr - packet pts) across packets emitted this call: 0 =
                              // same-frame-out, N = VT holding N frames internally (Q3/Q4-c).
    std::int64_t age_last = 0; // (frame_nr - packet pts) of the last packet emitted this call.
    std::uint64_t packets_emitted = 0; // packets emitted this call (feeds enc_inflight accounting).
    std::uint64_t bytes_emitted = 0;
    std::uint64_t pts_miss = 0; // packets this call whose pts != frame_nr (stale/in-flight packet).
    double call_ms = 0.0; // wall time of avcodec_send_frame + the receive_packet drain loop below.
  };

  int encode_avcodec(int64_t frame_nr, avcodec_encode_session_t &session, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp, bool *out_keyframe_emitted = nullptr, perf_encode_call_stats_t *out_perf = nullptr, const safe::mail_raw_t::event_t<bool> &shutdown_event = {}, bool bounded_packets = false) {
    if (out_keyframe_emitted) {
      *out_keyframe_emitted = false;
    }

    auto &frame = session.device->frame;
    frame->pts = frame_nr;

    auto &ctx = session.avcodec_ctx;

    auto &sps = session.sps;
    auto &vps = session.vps;

    // Encoder-latency instrumentation: times avcodec_send_frame + the receive_packet drain
    // loop below as one block (perf_trace's enc_call_max_ms). Zero cost when off: one bool
    // load plus a null-pointer check; no steady_clock calls unless perf_trace is enabled.
    const bool perf_on = out_perf && config::video.perf_trace;

    // Backlog-plateau cure (2026-07-14, docs/design/2026-07-14-vt-backlog-reinit-cure.md): the
    // cure's decision tick in encode_run() needs call_ms in production, where perf_trace is
    // normally off. time_call ungates the timing bracket below on the cure being active instead
    // of (only) on perf_trace -- age_max/age_last/pts_miss stay perf_on-gated below: they're
    // diagnostic-only and the cure doesn't read them. Cost when the cure is active: two extra
    // steady_clock::now() calls per encode (~tens of ns at 60fps).
    const bool cure_active = config::video.vt.vt_sync_output &&
                              config::video.vt.vt_sync_deadline_us > 0 &&
                              config::video.vt.vt_reinit_cure;
    const bool time_call = out_perf && (config::video.perf_trace || cure_active);
    std::chrono::steady_clock::time_point perf_call_start;
    if (time_call) {
      perf_call_start = std::chrono::steady_clock::now();
    }

    // send the frame to the encoder
    auto ret = avcodec_send_frame(ctx.get(), frame);
    if (ret < 0) {
      char err_str[AV_ERROR_MAX_STRING_SIZE] {0};
      BOOST_LOG(error) << "Could not send a frame for encoding: "sv << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, ret);

      return -1;
    }
    session.frame_timestamps[frame_nr] = frame_timestamp;
    while (session.frame_timestamps.size() > 64) {
      session.frame_timestamps.erase(session.frame_timestamps.begin());
    }

    while (ret >= 0) {
      auto packet = std::make_unique<packet_raw_avcodec>();
      auto av_packet = packet.get()->av_packet;

      ret = avcodec_receive_packet(ctx.get(), av_packet);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        if (time_call) {
          out_perf->call_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - perf_call_start).count();
        }
        return 0;
      } else if (ret < 0) {
        return ret;
      }

      if (av_packet->flags & AV_PKT_FLAG_KEY) {
        BOOST_LOG(debug) << "Frame "sv << frame_nr << ": IDR Keyframe (AV_FRAME_FLAG_KEY)"sv;
        if (out_keyframe_emitted) {
          *out_keyframe_emitted = true;
        }
      }

      if (session.inject) {
        auto replacements = std::make_shared<std::vector<packet_raw_t::replace_t>>();
        if (session.inject == 1) {
          auto h264 = cbs::make_sps_h264(ctx.get(), av_packet);

          sps = std::move(h264.sps);
        } else {
          auto hevc = cbs::make_sps_hevc(ctx.get(), av_packet);

          sps = std::move(hevc.sps);
          vps = std::move(hevc.vps);

          replacements->emplace_back(
            std::string_view((char *) std::begin(vps.old), vps.old.size()),
            std::string_view((char *) std::begin(vps._new), vps._new.size())
          );
        }

        session.inject = 0;

        replacements->emplace_back(
          std::string_view((char *) std::begin(sps.old), sps.old.size()),
          std::string_view((char *) std::begin(sps._new), sps._new.size())
        );
        session.replacements = std::move(replacements);
      }

      if (av_packet) {
        auto stamp = session.frame_timestamps.find(av_packet->pts);
        if (stamp != session.frame_timestamps.end()) {
          packet->frame_timestamp = stamp->second;
          session.frame_timestamps.erase(stamp);
        }
      }
      if (av_packet && av_packet->pts != frame_nr) {
        // In-flight/stale packet: how many frame_nrs newer than this packet's own pts have
        // already been sent -- the live equivalent of the b7ce0a8e synthetic-harness ~12-frame
        // finding (test_videotoolbox.cpp OnDemandIdrPipelineLatencyDocumented), measured live
        // per-packet instead of offline. Counted here regardless of perf_trace state gating
        // below only affects whether it's aggregated/reported (Q4-c).
        //
        // vt_sync_deadline_us addendum (2026-07-14, deadline-bounded-pop design): when
        // sync_output=1 and a deadline is active, a single-cycle deferral (age == 1 -- this
        // frame's packet came back exactly one send later, having missed one deadline-bounded
        // pop) is the INTENDED degradation path, not an encoder anomaly -- see
        // docs/design/2026-07-13-vt-sync-output.md's deadline addendum. Counting age == 1 as
        // a "miss" here would make enc_pts_miss spike under ordinary transient load even
        // though the feature is working exactly as designed, defeating its use as an
        // acceptance/regression signal (the design doc's "enc_pts_miss ~= 0" criterion).
        // Only age >= 2 -- more backlog than a single bounded wait can explain, i.e. VT is
        // genuinely falling behind -- still counts as a miss here. With sync_output=0, or
        // sync_output=1 with deadline_us == 0 (unbounded, pre-existing behavior), the
        // threshold collapses back to the original semantics: any age > 0 is a miss, since
        // neither mode has a legitimate reason to defer by exactly one frame.
        if (perf_on) {
          const bool deadline_active = config::video.vt.vt_sync_output && config::video.vt.vt_sync_deadline_us > 0;
          const std::int64_t age_for_pts_miss = frame_nr - av_packet->pts;
          if (age_for_pts_miss > (deadline_active ? 1 : 0)) {
            ++out_perf->pts_miss;
          }
        }
      }

      // packets_emitted is kept always-on (not perf_on-gated) as of the catch-up-drain fix
      // (2026-07-14): encode_run()'s inflight bookkeeping (perf_sends_total/perf_packets_total)
      // needs an accurate live signal to decide when to burst-drain backlog, in production, not
      // only when perf_trace debug logging is enabled. The increment itself is a single integer
      // add -- effectively free -- so ungating it costs nothing measurable. age_last/age_max
      // remain perf_on-gated: they're diagnostic-only and not read by the catch-up-drain logic.
      if (out_perf && av_packet) {
        ++out_perf->packets_emitted;
        out_perf->bytes_emitted += av_packet->size;
      }
      if (out_perf && av_packet) {
        std::int64_t age = frame_nr - av_packet->pts;
        out_perf->age_last = age;
        if (age > out_perf->age_max) {
          out_perf->age_max = age;
        }
      }

      packet->replacements = session.replacements;
      packet->channel_data = channel_data;
      packet->channel_owner = session.channel_owner.lock();
      if (bounded_packets && shutdown_event) {
        if (!packets->raise_wait(1, [&] { return bool(shutdown_event->view(0ms)); }, std::move(packet))) return 0;
      } else {
        packets->raise(std::move(packet));
      }
    }

    return 0;
  }

#ifndef __APPLE__
  int encode_nvenc(int64_t frame_nr, nvenc_encode_session_t &session, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp, bool *out_keyframe_emitted = nullptr, const safe::mail_raw_t::event_t<bool> &shutdown_event = {}, bool bounded_packets = false) {
    auto encoded_frame = session.encode_frame(frame_nr);
    if (encoded_frame.data.empty()) {
      BOOST_LOG(error) << "NvENC returned empty packet";
      return -1;
    }

    if (frame_nr != encoded_frame.frame_index) {
      BOOST_LOG(error) << "NvENC frame index mismatch " << frame_nr << " " << encoded_frame.frame_index;
    }

    if (out_keyframe_emitted) {
      *out_keyframe_emitted = encoded_frame.idr;
    }

    auto packet = std::make_unique<packet_raw_generic>(std::move(encoded_frame.data), encoded_frame.frame_index, encoded_frame.idr);
    packet->channel_data = channel_data;
    packet->channel_owner = session.channel_owner.lock();
    packet->after_ref_frame_invalidation = encoded_frame.after_ref_frame_invalidation;
    packet->frame_timestamp = frame_timestamp;
    if (bounded_packets && shutdown_event) {
      if (!packets->raise_wait(1, [&] { return bool(shutdown_event->view(0ms)); }, std::move(packet))) return 0;
    } else {
      packets->raise(std::move(packet));
    }

    return 0;
  }
#endif

  int encode(int64_t frame_nr, encode_session_t &session, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp, bool *out_keyframe_emitted = nullptr, perf_encode_call_stats_t *out_perf = nullptr, const safe::mail_raw_t::event_t<bool> &shutdown_event = {}, bool bounded_packets = false) {
    if (auto avcodec_session = dynamic_cast<avcodec_encode_session_t *>(&session)) {
      return encode_avcodec(frame_nr, *avcodec_session, packets, channel_data, frame_timestamp, out_keyframe_emitted, out_perf, shutdown_event, bounded_packets);
    }
#ifndef __APPLE__
    else if (auto nvenc_session = dynamic_cast<nvenc_encode_session_t *>(&session)) {
      return encode_nvenc(frame_nr, *nvenc_session, packets, channel_data, frame_timestamp, out_keyframe_emitted, shutdown_event, bounded_packets);
    }
#endif

    return -1;
  }

  std::unique_ptr<avcodec_encode_session_t> make_avcodec_encode_session(
    platf::display_t *disp,
    const encoder_t &encoder,
    const config_t &config,
    int width,
    int height,
    std::unique_ptr<platf::avcodec_encode_device_t> encode_device
  ) {
    auto platform_formats = dynamic_cast<const encoder_platform_formats_avcodec *>(encoder.platform_formats.get());
    if (!platform_formats) {
      return nullptr;
    }

    bool hardware = platform_formats->avcodec_base_dev_type != AV_HWDEVICE_TYPE_NONE;

    auto &video_format = encoder.codec_from_config(config);
    if (!video_format[encoder_t::PASSED] || !disp->is_codec_supported(video_format.name, config)) {
      BOOST_LOG(error) << encoder.name << ": "sv << video_format.name << " mode not supported"sv;
      return nullptr;
    }

    if (config.dynamicRange && !video_format[encoder_t::DYNAMIC_RANGE]) {
      BOOST_LOG(error) << video_format.name << ": dynamic range not supported"sv;
      return nullptr;
    }

    if (config.chromaSamplingType == 1 && !video_format[encoder_t::YUV444]) {
      BOOST_LOG(error) << video_format.name << ": YUV 4:4:4 not supported"sv;
      return nullptr;
    }

    auto codec = avcodec_find_encoder_by_name(video_format.name.c_str());
    if (!codec) {
      BOOST_LOG(error) << "Couldn't open ["sv << video_format.name << ']';

      return nullptr;
    }

    auto colorspace = encode_device->colorspace;
    auto sw_fmt = (colorspace.bit_depth == 8 && config.chromaSamplingType == 0)  ? platform_formats->avcodec_pix_fmt_8bit :
                  (colorspace.bit_depth == 8 && config.chromaSamplingType == 1)  ? platform_formats->avcodec_pix_fmt_yuv444_8bit :
                  (colorspace.bit_depth == 10 && config.chromaSamplingType == 0) ? platform_formats->avcodec_pix_fmt_10bit :
                  (colorspace.bit_depth == 10 && config.chromaSamplingType == 1) ? platform_formats->avcodec_pix_fmt_yuv444_10bit :
                                                                                   AV_PIX_FMT_NONE;

    // Allow up to 1 retry to apply the set of fallback options.
    //
    // Note: If we later end up needing multiple sets of
    // fallback options, we may need to allow more retries
    // to try applying each set.
    avcodec_ctx_t ctx;
    for (int retries = 0; retries < 2; retries++) {
      ctx.reset(avcodec_alloc_context3(codec));
      ctx->width = config.width;
      ctx->height = config.height;
      ctx->time_base = AVRational {1, config.framerate};
      ctx->framerate = AVRational {config.framerate, 1};
      if (config.framerateX100 > 0) {
        AVRational fps = video::framerateX100_to_rational(config.framerateX100);
        ctx->framerate = fps;
        ctx->time_base = AVRational {fps.den, fps.num};
      }

      switch (config.videoFormat) {
        case 0:
          // 10-bit h264 encoding is not supported by our streaming protocol
          assert(!config.dynamicRange);
          ctx->profile = (config.chromaSamplingType == 1) ? AV_PROFILE_H264_HIGH_444_PREDICTIVE : AV_PROFILE_H264_HIGH;
          break;

        case 1:
          if (config.chromaSamplingType == 1) {
            // HEVC uses the same RExt profile for both 8 and 10 bit YUV 4:4:4 encoding
            ctx->profile = AV_PROFILE_HEVC_REXT;
          } else {
            ctx->profile = config.dynamicRange ? AV_PROFILE_HEVC_MAIN_10 : AV_PROFILE_HEVC_MAIN;
          }
          break;

        case 2:
          // AV1 supports both 8 and 10 bit encoding with the same Main profile
          // but YUV 4:4:4 sampling requires High profile
          ctx->profile = (config.chromaSamplingType == 1) ? AV_PROFILE_AV1_HIGH : AV_PROFILE_AV1_MAIN;
          break;
      }

      // B-frames delay decoder output, so never use them
      ctx->max_b_frames = 0;

      // Use an infinite GOP length since I-frames are generated on demand
      // Exception: encoders with FIXED_GOP_SIZE flag don't support on-demand IDR
      if (encoder.flags & FIXED_GOP_SIZE) {
        // Fixed GOP for encoders that don't support on-demand IDR (e.g. Media Foundation)
        ctx->gop_size = 120;  // ~2 seconds at 60 FPS - larger to reduce oversized IDR frame frequency
        ctx->keyint_min = 120;
      } else {
        ctx->gop_size = encoder.flags & LIMITED_GOP_SIZE ?
                          std::numeric_limits<std::int16_t>::max() :
                          std::numeric_limits<int>::max();
        ctx->keyint_min = std::numeric_limits<int>::max();
      }

      // Some client decoders have limits on the number of reference frames
      if (config.numRefFrames) {
        if (video_format[encoder_t::REF_FRAMES_RESTRICT]) {
          ctx->refs = config.numRefFrames;
          // Encoders like h264_videotoolbox ignore avctx->refs and only honor their
          // private max_ref_frames option. Without this, VT emits 2-ref P-frames into
          // a stream the client negotiated at 1 ref -> "number of reference frames
          // exceeds max" decoder errors and garbled video on the Moonlight side.
          if (av_opt_find(ctx->priv_data, "max_ref_frames", nullptr, 0, 0)) {
            av_opt_set_int(ctx->priv_data, "max_ref_frames", config.numRefFrames, 0);
          }
        } else {
          BOOST_LOG(warning) << "Client requested reference frame limit, but encoder doesn't support it!"sv;
        }
      }

      // We forcefully reset the flags to avoid clash on reuse of AVCodecContext
      ctx->flags = 0;
      ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;
      if (encoder.name == "videotoolbox"sv && !config::video.vt.vt_low_delay) {
        // lavc 62 videotoolboxenc: LOW_DELAY combined with max_ref_frames=1 makes VT
        // emit only every OTHER frame (bisected empirically 2026-07-10: in=120 out=60,
        // pts 1,3,5...) -> a 60fps stream arrives as 30fps with "50% network drops" on
        // the Moonlight side. VT latency is governed by realtime/prio_speed and B-frames
        // are already disabled, so the flag buys nothing here.
        //
        // LOW_DELAY also drives kVTVideoEncoderSpecification_EnableLowLatencyRateControl
        // at VT session creation -- one-in-one-out, no internal frame queue. Live
        // instrumentation (this branch's measurement pass) shows 2-3 frames held inside
        // VT without it, i.e. 33-50ms of latency this strip is silently paying every
        // session, on every encoder, regardless of the every-other-frame bug.
        //
        // RE-TESTED 2026-11-01 on macOS 27 / M4 Pro: VT no longer emits every other frame, and
        // alone it returns frames in a steady 13.9 ms. But at 2880x1800@60 the encoder is then at
        // capacity with real frames, and host delay sits at 35-52 ms at any bitrate from 20 to
        // 64 Mbps, against 1-30 ms without it. See
        // docs/design/2026-11-01-capture-cadence-and-automatic-bitrate.md. Lower resolutions
        // are untested. config::video.vt.vt_low_delay stays a default-off experiment.
        ctx->flags &= ~AV_CODEC_FLAG_LOW_DELAY;
      }

      ctx->flags2 |= AV_CODEC_FLAG2_FAST;

      auto avcodec_colorspace = avcodec_colorspace_from_sunshine_colorspace(colorspace);

      ctx->color_range = avcodec_colorspace.range;
      ctx->color_primaries = avcodec_colorspace.primaries;
      ctx->color_trc = avcodec_colorspace.transfer_function;
      ctx->colorspace = avcodec_colorspace.matrix;

      // Used by cbs::make_sps_hevc
      ctx->sw_pix_fmt = sw_fmt;

      if (hardware) {
        avcodec_buffer_t encoding_stream_context;

        ctx->pix_fmt = platform_formats->avcodec_dev_pix_fmt;

        // Create the base hwdevice context
        auto buf_or_error = platform_formats->init_avcodec_hardware_input_buffer(encode_device.get());
        if (buf_or_error.has_right()) {
          return nullptr;
        }
        encoding_stream_context = std::move(buf_or_error.left());

        // If this encoder requires derivation from the base, derive the desired type
        if (platform_formats->avcodec_derived_dev_type != AV_HWDEVICE_TYPE_NONE) {
          avcodec_buffer_t derived_context;

          // Allow the hwdevice to prepare for this type of context to be derived
          if (encode_device->prepare_to_derive_context(platform_formats->avcodec_derived_dev_type)) {
            return nullptr;
          }

          auto err = av_hwdevice_ctx_create_derived(&derived_context, platform_formats->avcodec_derived_dev_type, encoding_stream_context.get(), 0);
          if (err) {
            char err_str[AV_ERROR_MAX_STRING_SIZE] {0};
            BOOST_LOG(error) << "Failed to derive device context: "sv << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, err);

            return nullptr;
          }

          encoding_stream_context = std::move(derived_context);
        }

        // Initialize avcodec hardware frames
        {
          avcodec_buffer_t frame_ref {av_hwframe_ctx_alloc(encoding_stream_context.get())};

          auto frame_ctx = (AVHWFramesContext *) frame_ref->data;
          frame_ctx->format = ctx->pix_fmt;
          frame_ctx->sw_format = sw_fmt;
          frame_ctx->height = ctx->height;
          frame_ctx->width = ctx->width;
          frame_ctx->initial_pool_size = 0;

          // Allow the hwdevice to modify hwframe context parameters
          encode_device->init_hwframes(frame_ctx);

          if (auto err = av_hwframe_ctx_init(frame_ref.get()); err < 0) {
            return nullptr;
          }

          ctx->hw_frames_ctx = av_buffer_ref(frame_ref.get());
        }

        ctx->slices = config.slicesPerFrame;
      } else /* software */ {
        ctx->pix_fmt = sw_fmt;

        // Clients will request for the fewest slices per frame to get the
        // most efficient encode, but we may want to provide more slices than
        // requested to ensure we have enough parallelism for good performance.
        ctx->slices = std::max(config.slicesPerFrame, config::video.min_threads);
      }

      if (encoder.flags & SINGLE_SLICE_ONLY) {
        ctx->slices = 1;
      }

      ctx->thread_type = FF_THREAD_SLICE;
      ctx->thread_count = ctx->slices;

      AVDictionary *options {nullptr};
      auto handle_option = [&options, &config](const encoder_t::option_t &option) {
        std::visit(
          util::overloaded {
            [&](int v) {
              av_dict_set_int(&options, option.name.c_str(), v, 0);
            },
            [&](int *v) {
              av_dict_set_int(&options, option.name.c_str(), *v, 0);
            },
            [&](std::optional<int> *v) {
              if (*v) {
                av_dict_set_int(&options, option.name.c_str(), **v, 0);
              }
            },
            [&](const std::function<int()> &v) {
              av_dict_set_int(&options, option.name.c_str(), v(), 0);
            },
            [&](const std::string &v) {
              av_dict_set(&options, option.name.c_str(), v.c_str(), 0);
            },
            [&](std::string *v) {
              if (!v->empty()) {
                av_dict_set(&options, option.name.c_str(), v->c_str(), 0);
              }
            },
            [&](const std::function<const std::string(const config_t &cfg)> &v) {
              av_dict_set(&options, option.name.c_str(), v(config).c_str(), 0);
            }
          },
          option.value
        );
      };

      // Apply common options, then format-specific overrides
      for (auto &option : video_format.common_options) {
        handle_option(option);
      }
      for (auto &option : (config.dynamicRange ? video_format.hdr_options : video_format.sdr_options)) {
        handle_option(option);
      }
      if (config.chromaSamplingType == 1) {
        for (auto &option : (config.dynamicRange ? video_format.hdr444_options : video_format.sdr444_options)) {
          handle_option(option);
        }
      }
      if (retries > 0) {
        for (auto &option : video_format.fallback_options) {
          handle_option(option);
        }
      }

      auto bitrate = ((config::video.max_bitrate > 0) ? std::min(config.bitrate, config::video.max_bitrate) : config.bitrate) * 1000;
      BOOST_LOG(info) << "Streaming bitrate is " << bitrate;
      ctx->rc_max_rate = bitrate;
      ctx->bit_rate = bitrate;

      if (encoder.flags & CBR_WITH_VBR) {
        // Ensure rc_max_bitrate != bit_rate to force VBR mode
        ctx->bit_rate--;
      } else {
        ctx->rc_min_rate = bitrate;
      }

      if (encoder.flags & RELAXED_COMPLIANCE) {
        ctx->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
      }

      if (!(encoder.flags & NO_RC_BUF_LIMIT)) {
        if (!hardware && (ctx->slices > 1 || config.videoFormat == 1)) {
          // Use a larger rc_buffer_size for software encoding when slices are enabled,
          // because libx264 can severely degrade quality if the buffer is too small.
          // libx265 encounters this issue more frequently, so always scale the
          // buffer by 1.5x for software HEVC encoding.
          ctx->rc_buffer_size = bitrate / ((config.framerate * 10) / 15);
        } else {
          ctx->rc_buffer_size = bitrate / config.framerate;

#ifndef __APPLE__
          if (encoder.name == "nvenc" && config::video.nv_legacy.vbv_percentage_increase > 0) {
            ctx->rc_buffer_size += ctx->rc_buffer_size * config::video.nv_legacy.vbv_percentage_increase / 100;
          }
#endif
        }
      }

      // Allow the encoding device a final opportunity to set/unset or override any options
      encode_device->init_codec_options(ctx.get(), &options);

      if (auto status = avcodec_open2(ctx.get(), codec, &options)) {
        char err_str[AV_ERROR_MAX_STRING_SIZE] {0};

        if (!video_format.fallback_options.empty() && retries == 0) {
          BOOST_LOG(info)
            << "Retrying with fallback configuration options for ["sv << video_format.name << "] after error: "sv
            << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, status);

          continue;
        } else {
          BOOST_LOG(error)
            << "Could not open codec ["sv
            << video_format.name << "]: "sv
            << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, status);

          return nullptr;
        }
      }

      // Successfully opened the codec
      break;
    }

    avcodec_frame_t frame {av_frame_alloc()};
    frame->format = ctx->pix_fmt;
    frame->width = ctx->width;
    frame->height = ctx->height;
    frame->color_range = ctx->color_range;
    frame->color_primaries = ctx->color_primaries;
    frame->color_trc = ctx->color_trc;
    frame->colorspace = ctx->colorspace;
    frame->chroma_location = ctx->chroma_sample_location;

    // Attach HDR metadata to the AVFrame
    if (colorspace_is_hdr(colorspace)) {
      SS_HDR_METADATA hdr_metadata;
      if (disp->get_hdr_metadata(hdr_metadata)) {
        auto mdm = av_mastering_display_metadata_create_side_data(frame.get());

        mdm->display_primaries[0][0] = av_make_q(hdr_metadata.displayPrimaries[0].x, 50000);
        mdm->display_primaries[0][1] = av_make_q(hdr_metadata.displayPrimaries[0].y, 50000);
        mdm->display_primaries[1][0] = av_make_q(hdr_metadata.displayPrimaries[1].x, 50000);
        mdm->display_primaries[1][1] = av_make_q(hdr_metadata.displayPrimaries[1].y, 50000);
        mdm->display_primaries[2][0] = av_make_q(hdr_metadata.displayPrimaries[2].x, 50000);
        mdm->display_primaries[2][1] = av_make_q(hdr_metadata.displayPrimaries[2].y, 50000);

        mdm->white_point[0] = av_make_q(hdr_metadata.whitePoint.x, 50000);
        mdm->white_point[1] = av_make_q(hdr_metadata.whitePoint.y, 50000);

        mdm->min_luminance = av_make_q(hdr_metadata.minDisplayLuminance, 10000);
        mdm->max_luminance = av_make_q(hdr_metadata.maxDisplayLuminance, 1);

        mdm->has_luminance = hdr_metadata.maxDisplayLuminance != 0 ? 1 : 0;
        mdm->has_primaries = hdr_metadata.displayPrimaries[0].x != 0 ? 1 : 0;

        if (hdr_metadata.maxContentLightLevel != 0 || hdr_metadata.maxFrameAverageLightLevel != 0) {
          auto clm = av_content_light_metadata_create_side_data(frame.get());

          clm->MaxCLL = hdr_metadata.maxContentLightLevel;
          clm->MaxFALL = hdr_metadata.maxFrameAverageLightLevel;
        }
      } else {
        BOOST_LOG(error) << "Couldn't get display hdr metadata when colorspace selection indicates it should have one";
      }
    }

    std::unique_ptr<platf::avcodec_encode_device_t> encode_device_final;

    if (!encode_device->data) {
      auto software_encode_device = std::make_unique<avcodec_software_encode_device_t>();

      if (software_encode_device->init(width, height, frame.get(), sw_fmt, hardware)) {
        return nullptr;
      }
      software_encode_device->colorspace = colorspace;

      encode_device_final = std::move(software_encode_device);
    } else {
      encode_device_final = std::move(encode_device);
    }

    if (encode_device_final->set_frame(frame.release(), ctx->hw_frames_ctx)) {
      return nullptr;
    }

    encode_device_final->apply_colorspace();

    auto session = std::make_unique<avcodec_encode_session_t>(
      std::move(ctx),
      std::move(encode_device_final),

      // 0 ==> don't inject, 1 ==> inject for h264, 2 ==> inject for hevc
      config.videoFormat <= 1 ? (1 - (int) video_format[encoder_t::VUI_PARAMETERS]) * (1 + config.videoFormat) : 0
    );

    return session;
  }

#ifndef __APPLE__
  std::unique_ptr<nvenc_encode_session_t> make_nvenc_encode_session(const config_t &client_config, std::unique_ptr<platf::nvenc_encode_device_t> encode_device) {
    if (!encode_device->init_encoder(client_config, encode_device->colorspace)) {
      return nullptr;
    }

    return std::make_unique<nvenc_encode_session_t>(std::move(encode_device));
  }
#endif

  std::unique_ptr<encode_session_t> make_encode_session(platf::display_t *disp, const encoder_t &encoder, const config_t &config, int width, int height, std::unique_ptr<platf::encode_device_t> encode_device) {
    std::unique_ptr<encode_session_t> session;
    if (dynamic_cast<platf::avcodec_encode_device_t *>(encode_device.get())) {
      auto avcodec_encode_device = boost::dynamic_pointer_cast<platf::avcodec_encode_device_t>(std::move(encode_device));
      session = make_avcodec_encode_session(disp, encoder, config, width, height, std::move(avcodec_encode_device));
    }
#ifndef __APPLE__
    else if (dynamic_cast<platf::nvenc_encode_device_t *>(encode_device.get())) {
      auto nvenc_encode_device = boost::dynamic_pointer_cast<platf::nvenc_encode_device_t>(std::move(encode_device));
      session = make_nvenc_encode_session(config, std::move(nvenc_encode_device));
    }
#endif

    if (session) session->channel_owner = config.channel_owner;
    return session;
  }

  void encode_run(
    int &frame_nr,  // Store progress of the frame number
    safe::mail_t mail,
    img_event_t images,
    config_t config,
    std::shared_ptr<platf::display_t> disp,
    std::unique_ptr<platf::encode_device_t> encode_device,
    safe::signal_t &reinit_event,
    const encoder_t &encoder,
    void *channel_data,
    // Backlog-plateau cure (2026-07-14, docs/design/2026-07-14-vt-backlog-reinit-cure.md).
    // In/out: on entry, true iff the PREVIOUS encode_run() call ended because the cure fired (so
    // if make_encode_session() below fails, we know to permanently disable the cure rather than
    // risk a cure-driven retry spin); overwritten before return with whether THIS session ends
    // because the cure fired, so capture_async() can pass it straight into the next call.
    bool &cure_rebuild,
    // Persistent kill-flag for the rest of the stream (capture_async-scope, like frame_nr):
    // once a cure-triggered rebuild fails, the cure goes inert for the remainder of the stream.
    // The age-based cooldown already bounds the cure's marginal risk on its own; this is the
    // optional belt-and-suspenders containment from the design's §4.
    bool &cure_disabled
  ) {
    const bool this_build_is_cure_rebuild = cure_rebuild;
    cure_rebuild = false;

    auto session = make_encode_session(disp.get(), encoder, config, disp->width, disp->height, std::move(encode_device));
    if (!session) {
      if (this_build_is_cure_rebuild) {
        cure_disabled = true;
        BOOST_LOG(warning) << "[cure] encoder rebuild failed right after a cure-triggered reinit -- disabling the backlog cure for the rest of this stream"sv;
      }
      return;
    }

    // As a workaround for NVENC hangs and to generally speed up encoder reinit,
    // we will complete the encoder teardown in a separate thread if supported.
    // This will move expensive processing off the encoder thread to allow us
    // to restart encoding as soon as possible. For cases where the NVENC driver
    // hang occurs, this thread may probably never exit, but it will allow
    // streaming to continue without requiring a full restart of Sunshine.
    auto fail_guard = util::fail_guard([&encoder, &session] {
      if (encoder.flags & ASYNC_TEARDOWN) {
        std::thread encoder_teardown_thread {[session = std::move(session)]() mutable {
          BOOST_LOG(info) << "Starting async encoder teardown";
          session.reset();
          BOOST_LOG(info) << "Async encoder teardown complete";
        }};
        encoder_teardown_thread.detach();
      }
    });

    // set max frame time based on client-requested target framerate.
    double minimum_fps_target = (config::video.minimum_fps_target > 0.0) ? config::video.minimum_fps_target : config.framerate;
    std::chrono::duration<double, std::milli> max_frametime {1000.0 / minimum_fps_target};
    // Report the ACTUAL keepalive floor + the ACTUAL timeout the encode loop waits on
    // (images->pop(max_frametime) below). The old message printed minimum_fps_target/2 and
    // max_frametime*2, which HID the beating case: at minimum_fps_target=60 the real timeout is
    // 16.67ms == the 60fps capture interval, so keepalive duplicates beat against real frames and
    // the sent rate climbs above 60 (Moonlight showed ~82) — yet the log claimed a harmless
    // "~30fps (33ms)". Print the truth so this is diagnosable from the log.
    BOOST_LOG(info) << "Minimum FPS target set to "sv << minimum_fps_target << "fps (keepalive timeout "sv << max_frametime.count() << "ms)"sv;

    if (config.adaptive_bitrate) session->request_idr_frame();
    auto shutdown_event = mail->event<bool>(mail::shutdown);
    auto packets = mail::man->queue<packet_t>(mail::video_packets);
    auto idr_events = mail->event<bool>(mail::idr);
    auto invalidate_ref_frames_events = mail->event<std::pair<int64_t, int64_t>>(mail::invalidate_ref_frames);

    {
      // Load a dummy image into the AVFrame to ensure we have something to encode
      // even if we timeout waiting on the first frame. This is a relatively large
      // allocation which can be freed immediately after convert(), so we do this
      // in a separate scope.
      auto dummy_img = disp->alloc_img();
      if (!dummy_img || disp->dummy_img(dummy_img.get()) || session->convert(*dummy_img)) {
        return;
      }
    }

    // Phase-0 perf_trace instrumentation (docs/design/pipeline-overhaul.md §2). Ships dark behind
    // config::video.perf_trace; all of this state below is only ever touched by this thread (the
    // encode thread), so plain (non-atomic) locals are fine. When perf_trace is false the only
    // per-iteration cost is one bool load.
    auto perf_trace_window_start = std::chrono::steady_clock::now();
    std::uint64_t perf_enc_in = 0;
    std::uint64_t perf_keepalive = 0;
    double perf_enc_iter_max_ms = 0.0;
    std::uint64_t perf_enc_over16 = 0;

    // Backlog-plateau cure state (2026-07-14, docs/design/2026-07-14-vt-backlog-reinit-cure.md).
    // Always-on (NOT perf_trace-gated) -- this must work in production where perf_trace is
    // normally off. session_start anchors session_age_s (also the free inter-cure cooldown: a
    // fresh session from any rebuild, cure-triggered or not, resets it to 0). cure_window_start/
    // cure_call_max_ms run their own independent 1s tick, separate from perf_trace_window_start
    // above, so the decision does not depend on perf_trace being enabled. cure_reinit is the
    // plain local break-flag OR'd into the encode-loop break test below -- see the design's §1b:
    // it must NEVER be reinit_event, which is capture-thread-owned and would deadlock if raised
    // from here.
    const auto session_start = std::chrono::steady_clock::now();
    auto cure_window_start = session_start;
    double cure_call_max_ms = 0.0;
    int cure_recovered_windows = 0;
    int cure_backlog_windows = 0;
    std::int64_t cure_age_min = INT64_MAX;
    bool cure_reinit = false;
    constexpr cure_params_t cure_params {};

    // Encoder-latency instrumentation (perf_trace; docs hunt: hunt-encoder-path.md Q3/Q4).
    // conv_max/enc_call_max are per-window maxima, same reporting pattern as enc_iter_max above.
    // enc_age_max is per-window max; enc_age_last is the most-recently-observed value and is
    // intentionally NOT reset each window (it just holds until the next packet updates it).
    // enc_inflight is a sampled gauge, not reset per window: cumulative frames sent minus
    // cumulative packets emitted over the life of this encode session -- the live equivalent of
    // the b7ce0a8e synthetic-harness ~12-frame finding (test_videotoolbox.cpp
    // OnDemandIdrPipelineLatencyDocumented), measured continuously instead of offline.
    double perf_conv_max_ms = 0.0;
    double perf_enc_call_max_ms = 0.0;
    std::int64_t perf_enc_age_max = 0;
    std::int64_t perf_enc_age_last = 0;
    std::uint64_t perf_enc_pts_miss = 0;
    std::uint64_t perf_sends_total = 0;
    std::uint64_t perf_packets_total = 0;

    // Capture-age instrumentation (perf_trace): the last unmeasured segment of the host
    // pipeline -- how old a REAL popped frame (img->frame_timestamp set) already is the instant
    // the encode loop's images->pop() returns it. cap_age_ms = now() - frame_timestamp decomposes
    // into (SCK composite+delivery latency) + (this loop's own mailbox dwell). The macOS stamp
    // lives in src/platform/macos/display.mm process_frame() (CMSampleBuffer presentation time,
    // domain-safe age subtraction, -5ms..+250ms sanity window — outside it the frame is left
    // unstamped and these counters simply skip it). Kept perf_trace-gated and additive so it's
    // dark by default, same as the other counters here.
    // perf_cap_age_avg_ms is a running mean (Welford-style incremental update), not a sum/count
    // pair, matching the "per-second running mean" ask; perf_cap_age_min_ms uses -1.0 as the
    // "no sample this window" sentinel (clamped to 0.0 when printed) since a real cap_age is
    // always >= 0.
    double perf_cap_age_min_ms = -1.0;
    double perf_cap_age_avg_ms = 0.0;
    double perf_cap_age_max_ms = 0.0;
    std::uint64_t perf_cap_age_samples = 0;

    // Frame-departure phase-lock (v2-A, docs/design/2026-07-13-cadence-phaselock.md §2). Modes
    // 0/1 (off / capture-side v1 timer): departure_phaselock is false, so
    // compute_departure_pop_timeout()/advance_departure_deadline() are no-ops and this loop's
    // behavior is byte-identical to today -- departure_next_deadline is computed but never
    // consulted. Mode 2: the mailbox pop waits on the absolute grid deadline instead of the flat
    // keepalive timeout.
    const bool departure_phaselock = (config::video.frame_departure_mode == 2);
    const std::chrono::duration<double> departure_interval_s {1.0 / (config.framerate > 0 ? config.framerate : 60)};
    const std::chrono::duration<double> departure_guard_s {config::video.departure_guard_ms / 1000.0};
    auto departure_next_deadline = std::chrono::steady_clock::now() +
                                    std::chrono::duration_cast<std::chrono::steady_clock::duration>(departure_interval_s + departure_guard_s);

    // Departure-gap perf_trace counters (docs/design/2026-07-13-cadence-phaselock.md §5.1).
    // Measured every iteration regardless of frame_departure_mode (gated only by
    // config::video.perf_trace, same as the rest of this instrumentation) so mode 1 (v1
    // baseline) and mode 2 (v2-A) produce directly comparable [perf] lines for the live A/B.
    // "Departure" = the instant immediately before encode() runs, once per loop iteration.
    bool perf_have_last_departure = false;
    std::chrono::steady_clock::time_point perf_last_departure_time;
    double perf_dep_gap_max_ms = 0.0;
    std::uint64_t perf_dep_gap_over_guard = 0;
    std::uint64_t perf_dep_real = 0;
    std::uint64_t perf_dep_backfill = 0;

    // Capture-stall visibility. Unlike perf_enc_in/perf_keepalive above, these counters
    // are NOT gated behind config::video.perf_trace: the keepalive path re-encodes the
    // dummy/stale frame on every timeout, so the client sees a healthy-looking stream
    // even if the capture backend never delivers a single real frame. That condition
    // must be diagnosable without opting into perf tracing. See
    // video::should_warn_capture_stalled() for the startup-grace rationale.
    std::uint64_t stall_real_frame_count = 0;
    std::uint64_t stall_loop_iterations = 0;
    bool warned_capture_stall_startup = false;
    auto stall_window_start = std::chrono::steady_clock::now();
    std::uint64_t stall_window_real_frames = 0;

    // Bounded server-side IDR re-arm (finding #3): if a requested on-demand IDR isn't
    // honored with an actual keyframe packet on the very next frame (observed on VideoToolbox
    // cold/negotiating sessions), keep re-arming the KEY flag for up to N more frames rather
    // than silently giving up after one miss. See should_rearm_idr() in video.h - event-driven
    // and bounded, so it cannot resurrect the FIXED_GOP_SIZE periodic-keyframe stutter.
    constexpr int idr_rearm_budget = 3;
    int idr_rearm_remaining = 0;
    int applied_bitrate = config.bitrate;
    int lowest_bitrate = config.bitrate;
    auto last_decrease = std::chrono::steady_clock::now();
    automatic_frame_budget frame_budget;

    while (true) {
      // Change the encoder's bitrate in place. One that can't is rebuilt at a bounded
      // cadence instead: capture, input, audio and transport owners remain alive, and
      // the initial rebuilt frame is IDR.
      if (config.adaptive_bitrate && config.adaptive_bitrate->target() != applied_bitrate) {
        const int wanted = config.adaptive_bitrate->target();
        const auto now = std::chrono::steady_clock::now();
        const auto session_age = now - session_start;
        if (wanted < applied_bitrate) last_decrease = now;
        if (rebuild_after_dip(wanted, lowest_bitrate, config.bitrate, config.adaptive_bitrate->ceiling(), session_age, now - last_decrease)) return;
        if (session->set_bitrate(wanted)) {
          applied_bitrate = wanted;
          lowest_bitrate = std::min(lowest_bitrate, wanted);
        }
        else if (session_age >= 2s) return;
      }
      bool requested_idr_frame = false;

      while (invalidate_ref_frames_events->peek()) {
        if (auto frames = invalidate_ref_frames_events->pop(0ms)) {
          session->invalidate_ref_frames(frames->first, frames->second);
        }
      }

      if (idr_events->peek()) {
        requested_idr_frame = true;
        idr_events->pop();
        idr_rearm_remaining = idr_rearm_budget;
      }

      if (requested_idr_frame || idr_rearm_remaining > 0) {
        // Idempotent - just ORs pict_type/AV_FRAME_FLAG_KEY back on. Re-asserted every armed
        // iteration so the flag is guaranteed set regardless of what convert() does to the
        // frame between requests.
        session->request_idr_frame();
      }

      std::optional<std::chrono::steady_clock::time_point> frame_timestamp;
      bool captured_new_frame = false;

      // Phase-0 perf_trace "E" (enc_iter): wraps the pop->convert->encode section below with
      // steady_clock; per-second max iteration ms + count>16.67ms (enc_over16), see the summary
      // emitted after encode() further down.
      std::chrono::steady_clock::time_point perf_iter_start;
      if (config::video.perf_trace) {
        perf_iter_start = std::chrono::steady_clock::now();
      }

      // Encode at a minimum FPS to avoid image quality issues with static content
      if (!requested_idr_frame || images->peek()) {
        // frame_departure_mode == 2 (v2-A): wait only up to the absolute departure grid
        // deadline instead of the flat keepalive timeout, so a real frame is popped and
        // emitted the instant it arrives. Modes 0/1: pop_timeout == max_frametime, unchanged.
        auto pop_timeout = compute_departure_pop_timeout(
          departure_phaselock,
          std::chrono::steady_clock::now(),
          departure_next_deadline,
          max_frametime
        );
        auto img = images->pop(pop_timeout);

        // Capture-age instrumentation: measured immediately after the pop returns, on a REAL
        // frame only (img->frame_timestamp set) -- see the counter declarations above for what
        // this decomposes into and the current macOS caveat.
        if (config::video.perf_trace && img && !img->cached_capture && img->frame_timestamp) {
          double cap_age_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - *img->frame_timestamp).count();
          ++perf_cap_age_samples;
          if (perf_cap_age_min_ms < 0.0 || cap_age_ms < perf_cap_age_min_ms) {
            perf_cap_age_min_ms = cap_age_ms;
          }
          if (cap_age_ms > perf_cap_age_max_ms) {
            perf_cap_age_max_ms = cap_age_ms;
          }
          perf_cap_age_avg_ms += (cap_age_ms - perf_cap_age_avg_ms) / static_cast<double>(perf_cap_age_samples);
        }

        // Phase-0 perf_trace "C" (enc_in vs keepalive): a real popped frame vs. the
        // max_frametime-timeout (keepalive) path.
        if (config::video.perf_trace) {
          if (img) {
            ++perf_enc_in;
          } else {
            ++perf_keepalive;
          }
        }

        // Capture-stall visibility (always-on, see declaration above).
        ++stall_loop_iterations;
        if (img && !img->cached_capture) {
          ++stall_real_frame_count;
          ++stall_window_real_frames;
        }

        if (!warned_capture_stall_startup && should_warn_capture_stalled(stall_real_frame_count, stall_loop_iterations)) {
          BOOST_LOG(warning) << "capture stalled: 0 real frames in first 3s — client is seeing the startup dummy frame (keepalive re-encoding)"sv;
          warned_capture_stall_startup = true;
          stall_window_start = std::chrono::steady_clock::now();
          stall_window_real_frames = 0;
        } else if (warned_capture_stall_startup) {
          auto stall_now = std::chrono::steady_clock::now();
          if (stall_now - stall_window_start >= 10s) {
            if (stall_window_real_frames == 0) {
              BOOST_LOG(warning) << "capture still stalled: 0 real frames in the last 10s — client is seeing the startup dummy frame (keepalive re-encoding)"sv;
            }
            stall_window_start = stall_now;
            stall_window_real_frames = 0;
          }
        }

        if (img) {
          // A repeat of the last capture still carries that capture's time. It isn't how
          // old this frame's pipeline is, and on a still desktop it would read as hundreds
          // of milliseconds of host delay.
          if (!img->cached_capture) frame_timestamp = img->frame_timestamp;
          captured_new_frame = !img->cached_capture;

          // Encoder-latency instrumentation "conv_max": times only this convert() call
          // (nv12_zero_device zero-copy CFRetain/AVBufferRef wrap on macOS/VT), separately from
          // the avcodec_send_frame+drain block timed inside encode_avcodec (enc_call_max) --
          // decomposes the existing enc_iter blob into its two dominant spans.
          std::chrono::steady_clock::time_point perf_convert_start;
          if (config::video.perf_trace) {
            perf_convert_start = std::chrono::steady_clock::now();
          }
          if (session->convert(*img)) {
            BOOST_LOG(error) << "Could not convert image"sv;
            return;
          }
          if (config::video.perf_trace) {
            auto convert_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - perf_convert_start).count();
            if (convert_ms > perf_conv_max_ms) {
              perf_conv_max_ms = convert_ms;
            }
          }
        } else if (!images->running()) {
          break;
        }
      }

      // Break out of the encoding loop if any of the following are true:
      // a) The stream is ending
      // b) Sunshine is quitting
      // c) The capture side is waiting to reinit and we've encoded at least one frame
      //
      // If we have to reinit before we have received any captured frames, we will encode
      // the blank dummy frame just to let Moonlight know that we're alive.
      //
      // Ensure that this check occurs as close as possible to the encode call to prevent packets
      // in flight after encoder teardown.
      if (shutdown_event->peek() || !images->running() || (reinit_event.peek() && frame_nr > 1) || cure_reinit) {
        break;
      }

      // The client saw a queue building on the network. Leaving out a frame or two
      // empties it long before a lower bitrate could.
      if (config.adaptive_bitrate && !requested_idr_frame && idr_rearm_remaining == 0 && frame_nr > 1 && config.adaptive_bitrate->client_driven() &&
          (config.adaptive_bitrate->take_drain_frame() || !frame_budget.allow(std::chrono::steady_clock::now(), applied_bitrate, config.framerate))) {
        continue;
      }

      // Frame-departure phase-lock re-phase + perf_trace departure-gap counters, both anchored
      // to the same "departure" instant: immediately before encode() runs, using whether this
      // iteration produced a real frame (frame_timestamp set) vs. a backfill/keepalive dup
      // (frame_timestamp still nullopt, covering both the max_frametime-timeout path and the
      // requested_idr_frame-with-empty-mailbox fast path above). Grid re-phase only takes effect
      // in mode 2 (departure_phaselock); the gap counters run whenever perf_trace is on,
      // independent of mode, so mode 1 and mode 2 [perf] lines are directly A/B-comparable
      // (docs/design/2026-07-13-cadence-phaselock.md §2.1, §5.1).
      {
        auto departure_now = std::chrono::steady_clock::now();
        bool departure_got_real_frame = captured_new_frame && frame_timestamp.has_value();

        departure_next_deadline = advance_departure_deadline(
          departure_phaselock,
          departure_got_real_frame,
          departure_now,
          departure_next_deadline,
          departure_interval_s
        );

        if (config::video.perf_trace) {
          if (perf_have_last_departure) {
            double gap_ms = std::chrono::duration<double, std::milli>(departure_now - perf_last_departure_time).count();
            if (gap_ms > perf_dep_gap_max_ms) {
              perf_dep_gap_max_ms = gap_ms;
            }
            double guard_threshold_ms = (departure_interval_s.count() + departure_guard_s.count()) * 1000.0;
            if (gap_ms > guard_threshold_ms) {
              ++perf_dep_gap_over_guard;
            }
          }
          perf_have_last_departure = true;
          perf_last_departure_time = departure_now;

          if (departure_got_real_frame) {
            ++perf_dep_real;
          } else {
            ++perf_dep_backfill;
          }
        }
      }

      bool idr_keyframe_emitted = false;
      bool was_arming_idr = idr_rearm_remaining > 0;

      perf_encode_call_stats_t perf_call_stats;
      if (encode(frame_nr++, *session, packets, channel_data, frame_timestamp, &idr_keyframe_emitted, &perf_call_stats, shutdown_event, bool(config.adaptive_bitrate))) {
        BOOST_LOG(error) << "Could not encode video packet"sv;
        return;
      }

      // Inflight bookkeeping (perf_sends_total/perf_packets_total) kept always-on, not
      // perf_trace-gated (2026-07-14): gives enc_inflight-equivalent visibility in production,
      // not only when perf_trace debug logging is enabled. The increments themselves are single
      // integer adds -- effectively free at 60fps.
      //
      // A Skylight-side "catch-up burst" (submit extra duplicate frames purely to buy extra pop
      // attempts, reusing the keepalive-dup mechanism) was implemented and empirically tested
      // here during the live-defect investigation (2026-07-14) and REMOVED after proving it
      // contributes nothing: ffmpeg's classic FF_CODEC_ENCODE_CB calling convention
      // (libavcodec/encode.c) pairs every successful pop 1:1 with a real avcodec_send_frame()
      // call -- so a burst tick's "extra pop" is exactly offset by the extra submission that
      // same tick required, netting zero change to inflight. Verified with an instrumented
      // standalone harness (scratchpad sync_deadline_check.c scenario d): burst-enabled and
      // burst-disabled runs against the SAME cap-patched lib produced byte-identical inflight
      // trajectories. Once backlog exists, this compat shim architecture makes it PERMANENT for
      // the life of the encode session (see the ffmpeg-side VT_SYNC_MAX_INFLIGHT comment for the
      // full "why" and why draining to literal 0 is not achievable without a real flush -- which
      // is not viable mid-session). The fix that remains and IS effective is prevention: the
      // ffmpeg-side cap bounds how large that permanent residual can ever get, and the deadline
      // feature keeps working for genuinely isolated single-frame misses. See the catch-up-drain
      // addendum in docs/design/2026-07-13-vt-sync-output.md for the complete investigation.
      ++perf_sends_total;
      perf_packets_total += perf_call_stats.packets_emitted;
      frame_budget.spent(perf_call_stats.bytes_emitted);

      // Backlog-plateau cure decision tick (2026-07-14,
      // docs/design/2026-07-14-vt-backlog-reinit-cure.md). Deliberately its own always-on 1s
      // tick, independent of the perf_trace-gated [perf] block below (config::video.perf_trace
      // is normally off in production) -- see the design's §2c. cure_active is re-evaluated every
      // iteration (not hoisted out of the loop) so vt_reinit_cure doubles as a live kill-switch:
      // flipping it off takes effect on the very next iteration, no session rebuild required.
      const bool cure_active = config::video.vt.vt_sync_output &&
                                config::video.vt.vt_sync_deadline_us > 0 &&
                                config::video.vt.vt_reinit_cure;
      if (cure_active && !cure_disabled && !cure_reinit) {
        if (perf_call_stats.call_ms > cure_call_max_ms) {
          cure_call_max_ms = perf_call_stats.call_ms;
        }
        if (perf_call_stats.packets_emitted > 0) {
          cure_age_min = std::min(cure_age_min, perf_call_stats.age_last);
        }

        auto cure_now = std::chrono::steady_clock::now();
        if (cure_now - cure_window_start >= 1s) {
          if (cure_call_max_ms < cure_params.recovery_call_ms) {
            ++cure_recovered_windows;
          } else {
            cure_recovered_windows = 0;
          }

          // How far behind the newest packet really is. Counting sends against packets
          // never forgets a frame VideoToolbox chose to drop, so it can report a backlog
          // that isn't there, and each false alarm costs a rebuild and a visible hitch.
          cure_backlog_windows = cure_age_min != INT64_MAX && cure_age_min >= cure_params.trigger_inflight ? cure_backlog_windows + 1 : 0;
          std::int64_t cure_enc_inflight = cure_backlog_windows >= cure_params.recovery_windows ? cure_age_min : 0;
          cure_age_min = INT64_MAX;
          double session_age_s = std::chrono::duration<double>(cure_now - session_start).count();

          if (should_reinit_for_backlog(cure_enc_inflight, cure_recovered_windows, session_age_s, cure_params)) {
            BOOST_LOG(info) << "[cure] encoder reinit: draining "sv << cure_enc_inflight
                             << "-frame backlog (call_ms fast for 3s)"sv;
            cure_reinit = true;
            cure_rebuild = true;
          }

          cure_window_start = cure_now;
          cure_call_max_ms = 0.0;
        }
      }

      if (config::video.perf_trace) {
        // Encoder-latency instrumentation: fold this call's stats (populated inside
        // encode_avcodec, see perf_encode_call_stats_t) into the per-second aggregates.
        perf_enc_pts_miss += perf_call_stats.pts_miss;
        if (perf_call_stats.packets_emitted > 0) {
          perf_enc_age_last = perf_call_stats.age_last;
        }
        if (perf_call_stats.age_max > perf_enc_age_max) {
          perf_enc_age_max = perf_call_stats.age_max;
        }
        if (perf_call_stats.call_ms > perf_enc_call_max_ms) {
          perf_enc_call_max_ms = perf_call_stats.call_ms;
        }

        auto iter_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - perf_iter_start).count();
        if (iter_ms > perf_enc_iter_max_ms) {
          perf_enc_iter_max_ms = iter_ms;
        }
        if (iter_ms > 16.67) {
          ++perf_enc_over16;
        }

        auto now = std::chrono::steady_clock::now();
        if (now - perf_trace_window_start >= 1s) {
          std::uint64_t sck_real = 0;
          std::uint64_t sck_idle = 0;
#ifdef __APPLE__
          // Phase-0 perf_trace "A"/"A'": SCK delivery callback counters (sc_capture.m), read
          // and reset for this window.
          sck_real = perf_trace_exchange_sck_real();
          sck_idle = perf_trace_exchange_sck_idle();
#endif
          // Phase-0 perf_trace "D" (mbox_drop): per-instance counter on this session's own
          // mailbox (safe::event_t<>, thread_safe.h) -- see raise()'s increment there.
          std::uint64_t mbox_drop = images->exchange_mbox_drop_count();

          // Phase-0 perf_trace "F": would_backfill = max(0, frameRate - sck_real).
          int would_backfill = std::max(0, config.framerate - static_cast<int>(sck_real));

          // Single-decimal formatter for the perf-log fields below -- was 7 copies of the same
          // `char buf[32]; std::snprintf(buf, sizeof(buf), "%.1f", v);` boilerplate, each grown
          // on organically across three commits (7330c412, c191bafd) as counters were added.
          // Output is byte-identical to the old per-field buffers (same snprintf call, same
          // format string); this only removes the copy-paste risk for the next counter.
          auto fmt1 = [](double v) {
            char b[32];
            std::snprintf(b, sizeof(b), "%.1f", v);
            return std::string(b);
          };

          // Departure-gap counters (docs/design/2026-07-13-cadence-phaselock.md §5.1): dep_real /
          // dep_backfill are departures-by-type this window; dep_gap_max is the max
          // inter-departure gap (a max, not p99 -- cheap and acceptable per the design's own
          // note); dep_gap_over_guard counts departures whose gap exceeded interval+guard (the
          // headline "would this have been a hole/stutter under v1's threshold" signal).
          // frame_departure_mode is logged so an A/B session's [perf] lines are self-describing.

          // Encoder-latency instrumentation (hunt-encoder-path.md Q3/Q4): enc_inflight is a
          // sampled gauge (cumulative sends minus cumulative packets emitted over the life of
          // this encode session), not a per-window count -- it answers "how many frames is the
          // encoder holding right now", same question the b7ce0a8e synthetic test answered
          // offline (~12 frames for h264_videotoolbox in steady state).
          std::int64_t enc_inflight = static_cast<std::int64_t>(perf_sends_total) - static_cast<std::int64_t>(perf_packets_total);

          // Capture-age (see counter declarations above): min/avg clamp to 0.0 when this window
          // saw zero real frames (perf_cap_age_min_ms sentinel is -1.0 in that case).

          BOOST_LOG(info) << "[perf] "sv
                           // capture / mailbox
                           << "sck_real="sv << sck_real
                           << " sck_idle="sv << sck_idle
                           << " enc_in="sv << perf_enc_in
                           << " keepalive="sv << perf_keepalive
                           << " mbox_drop="sv << mbox_drop
                           << " enc_iter_max="sv << fmt1(perf_enc_iter_max_ms) << "ms"sv
                           << " enc_over16="sv << perf_enc_over16
                           << " would_backfill="sv << would_backfill

                           // departure
                           << " dep_real="sv << perf_dep_real
                           << " dep_backfill="sv << perf_dep_backfill
                           << " dep_gap_max="sv << fmt1(perf_dep_gap_max_ms) << "ms"sv
                           << " dep_gap_over_guard="sv << perf_dep_gap_over_guard
                           << " departure_mode="sv << config::video.frame_departure_mode

                           // encoder
                           << " enc_age_max="sv << perf_enc_age_max
                           << " enc_age_last="sv << perf_enc_age_last
                           << " enc_inflight="sv << enc_inflight
                           << " conv_max="sv << fmt1(perf_conv_max_ms) << "ms"sv
                           << " enc_call_max="sv << fmt1(perf_enc_call_max_ms) << "ms"sv
                           << " enc_pts_miss="sv << perf_enc_pts_miss

                           // cap-age
                           << " cap_age_min="sv << fmt1(perf_cap_age_min_ms < 0.0 ? 0.0 : perf_cap_age_min_ms) << "ms"sv
                           << " cap_age_avg="sv << fmt1(perf_cap_age_avg_ms) << "ms"sv
                           << " cap_age_max="sv << fmt1(perf_cap_age_max_ms) << "ms"sv;

          perf_trace_window_start = now;
          perf_enc_in = 0;
          perf_keepalive = 0;
          perf_enc_iter_max_ms = 0.0;
          perf_enc_over16 = 0;
          perf_dep_real = 0;
          perf_dep_backfill = 0;
          perf_dep_gap_max_ms = 0.0;
          perf_dep_gap_over_guard = 0;
          perf_conv_max_ms = 0.0;
          perf_enc_call_max_ms = 0.0;
          perf_enc_age_max = 0;
          perf_enc_pts_miss = 0;
          perf_cap_age_min_ms = -1.0;
          perf_cap_age_avg_ms = 0.0;
          perf_cap_age_max_ms = 0.0;
          perf_cap_age_samples = 0;
          // perf_enc_age_last, perf_sends_total, perf_packets_total intentionally NOT reset:
          // age_last holds until the next packet updates it, and the sends/packets totals are
          // cumulative for enc_inflight's gauge semantics (see comment above).
        }
      }

      if (!should_rearm_idr(idr_keyframe_emitted, idr_rearm_remaining)) {
        if (was_arming_idr && !idr_keyframe_emitted) {
          // Exhausted the re-arm budget without ever seeing a keyframe - this is now a
          // genuine alarm (fires once per gave-up request, not once per single-frame miss).
          BOOST_LOG(error) << "Encoder did not produce IDR frame when requested!"sv;
        }
        session->request_normal_frame();
      }

      // While streaming check to see if the mouse is present and enable Mouse Keys to force the cursor to appear
      // This is useful for KVM switch scenarios where mouse may disappear during streaming
      platf::enable_mouse_keys();
    }
  }

  input::touch_port_t make_port(platf::display_t *display, const config_t &config) {
    float wd = display->width;
    float hd = display->height;

    float wt = config.width;
    float ht = config.height;

    auto scalar = std::fminf(wt / wd, ht / hd);

    // we initialize scalar_tpcoords and logical dimensions to default values in case they are not set (non-KMS)
    float scalar_tpcoords = 1.0f;
    int display_env_logical_width = 0;
    int display_env_logical_height = 0;
    if (display->logical_width && display->logical_height && display->env_logical_width && display->env_logical_height) {
      float lwd = display->logical_width;
      float lhd = display->logical_height;
      scalar_tpcoords = std::fminf(wd / lwd, hd / lhd);
      display_env_logical_width = display->env_logical_width;
      display_env_logical_height = display->env_logical_height;
    }

    auto w2 = scalar * wd;
    auto h2 = scalar * hd;

    auto offsetX = (config.width - w2) * 0.5f;
    auto offsetY = (config.height - h2) * 0.5f;

    return input::touch_port_t {
      {
        display->offset_x,
        display->offset_y,
        config.width,
        config.height,
      },
      display->env_width,
      display->env_height,
      offsetX,
      offsetY,
      1.0f / scalar,
      scalar_tpcoords,
      display_env_logical_width,
      display_env_logical_height
    };
  }

  std::unique_ptr<platf::encode_device_t> make_encode_device(platf::display_t &disp, const encoder_t &encoder, const config_t &config) {
    std::unique_ptr<platf::encode_device_t> result;

    auto colorspace = colorspace_from_client_config(config, disp.is_hdr());

    platf::pix_fmt_e pix_fmt;
    if (config.chromaSamplingType == 1) {
      // YUV 4:4:4
      if (!(encoder.flags & YUV444_SUPPORT)) {
        // Encoder can't support YUV 4:4:4 regardless of hardware capabilities
        return {};
      }
      pix_fmt = (colorspace.bit_depth == 10) ?
                  encoder.platform_formats->pix_fmt_yuv444_10bit :
                  encoder.platform_formats->pix_fmt_yuv444_8bit;
    } else {
      // YUV 4:2:0
      pix_fmt = (colorspace.bit_depth == 10) ?
                  encoder.platform_formats->pix_fmt_10bit :
                  encoder.platform_formats->pix_fmt_8bit;
    }

    {
      auto encoder_name = encoder.codec_from_config(config).name;

      BOOST_LOG(info) << "Creating encoder " << logging::bracket(encoder_name);

      auto color_coding = colorspace.colorspace == colorspace_e::bt2020    ? "HDR (Rec. 2020 + SMPTE 2084 PQ)" :
                          colorspace.colorspace == colorspace_e::rec601    ? "SDR (Rec. 601)" :
                          colorspace.colorspace == colorspace_e::rec709    ? "SDR (Rec. 709)" :
                          colorspace.colorspace == colorspace_e::bt2020sdr ? "SDR (Rec. 2020)" :
                                                                             "unknown";

      BOOST_LOG(info) << "Color coding: " << color_coding;
      BOOST_LOG(info) << "Color depth: " << colorspace.bit_depth << "-bit";
      BOOST_LOG(info) << "Color range: " << (colorspace.full_range ? "JPEG" : "MPEG");
    }

    if (dynamic_cast<const encoder_platform_formats_avcodec *>(encoder.platform_formats.get())) {
      result = disp.make_avcodec_encode_device(pix_fmt);
    } else if (dynamic_cast<const encoder_platform_formats_nvenc *>(encoder.platform_formats.get())) {
      result = disp.make_nvenc_encode_device(pix_fmt);
    }

    if (result) {
      result->colorspace = colorspace;
    }

    return result;
  }

  std::optional<sync_session_t> make_synced_session(platf::display_t *disp, const encoder_t &encoder, platf::img_t &img, sync_session_ctx_t &ctx) {
    sync_session_t encode_session;

    encode_session.ctx = &ctx;

    auto encode_device = make_encode_device(*disp, encoder, ctx.config);
    if (!encode_device) {
      return std::nullopt;
    }

    // absolute mouse coordinates require that the dimensions of the screen are known
    ctx.touch_port_events->raise(make_port(disp, ctx.config));

    // Update client with our current HDR display state
    hdr_info_t hdr_info = std::make_unique<hdr_info_raw_t>(false);
    if (colorspace_is_hdr(encode_device->colorspace)) {
      if (disp->get_hdr_metadata(hdr_info->metadata)) {
        hdr_info->enabled = true;
      } else {
        BOOST_LOG(error) << "Couldn't get display hdr metadata when colorspace selection indicates it should have one";
      }
    }
    ctx.hdr_events->raise(std::move(hdr_info));

    auto session = make_encode_session(disp, encoder, ctx.config, img.width, img.height, std::move(encode_device));
    if (!session) {
      return std::nullopt;
    }

    // Load the initial image to prepare for encoding
    if (session->convert(img)) {
      BOOST_LOG(error) << "Could not convert initial image"sv;
      return std::nullopt;
    }

    encode_session.session = std::move(session);

    return encode_session;
  }

  encode_e encode_run_sync(
    std::vector<std::unique_ptr<sync_session_ctx_t>> &synced_session_ctxs,
    encode_session_ctx_queue_t &encode_session_ctx_queue,
    std::vector<std::string> &display_names,
    int &display_p
  ) {
    const auto &encoder = *chosen_encoder;

    std::shared_ptr<platf::display_t> disp;

    auto switch_display_event = mail::man->event<int>(mail::switch_display);

    if (synced_session_ctxs.empty()) {
      auto ctx = encode_session_ctx_queue.pop();
      if (!ctx) {
        return encode_e::ok;
      }

      synced_session_ctxs.emplace_back(std::make_unique<sync_session_ctx_t>(std::move(*ctx)));
    }

    while (encode_session_ctx_queue.running()) {
      // Refresh display names since a display removal might have caused the reinitialization
      refresh_displays(encoder.platform_formats->dev_type, display_names, display_p);

      // Process any pending display switch with the new list of displays
      if (switch_display_event->peek()) {
        // peek() and pop() are not atomic, so a concurrent stop() can still leave
        // pop() with nothing to return even though peek() just saw a value.
        if (auto switch_display = switch_display_event->pop()) {
          display_p = std::clamp(*switch_display, 0, (int) display_names.size() - 1);
        }
      }

      // reset_display() will sleep between retries
      reset_display(disp, encoder.platform_formats->dev_type, display_names[display_p], synced_session_ctxs.front()->config);
      if (disp) {
        break;
      }
    }

    if (!disp) {
      return encode_e::error;
    }

    auto img = disp->alloc_img();
    if (!img || disp->dummy_img(img.get())) {
      return encode_e::error;
    }

    std::vector<sync_session_t> synced_sessions;
    for (auto &ctx : synced_session_ctxs) {
      auto synced_session = make_synced_session(disp.get(), encoder, *img, *ctx);
      if (!synced_session) {
        return encode_e::error;
      }

      synced_sessions.emplace_back(std::move(*synced_session));
    }

    auto ec = platf::capture_e::ok;
    while (encode_session_ctx_queue.running()) {
      auto push_captured_image_callback = [&](std::shared_ptr<platf::img_t> &&img, bool frame_captured) -> bool {
        while (encode_session_ctx_queue.peek()) {
          auto encode_session_ctx = encode_session_ctx_queue.pop();
          if (!encode_session_ctx) {
            return false;
          }

          synced_session_ctxs.emplace_back(std::make_unique<sync_session_ctx_t>(std::move(*encode_session_ctx)));

          auto encode_session = make_synced_session(disp.get(), encoder, *img, *synced_session_ctxs.back());
          if (!encode_session) {
            ec = platf::capture_e::error;
            return false;
          }

          synced_sessions.emplace_back(std::move(*encode_session));
        }

        KITTY_WHILE_LOOP(auto pos = std::begin(synced_sessions), pos != std::end(synced_sessions), {
          auto ctx = pos->ctx;
          if (ctx->shutdown_event->peek()) {
            // Let waiting thread know it can delete shutdown_event
            ctx->join_event->raise(true);

            pos = synced_sessions.erase(pos);
            synced_session_ctxs.erase(std::find_if(std::begin(synced_session_ctxs), std::end(synced_session_ctxs), [&ctx_p = ctx](auto &ctx) {
              return ctx.get() == ctx_p;
            }));

            if (synced_sessions.empty()) {
              return false;
            }

            continue;
          }

          if (ctx->idr_events->peek()) {
            pos->session->request_idr_frame();
            ctx->idr_events->pop();
          }

          if (frame_captured && pos->session->convert(*img)) {
            BOOST_LOG(error) << "Could not convert image"sv;
            ctx->shutdown_event->raise(true);

            continue;
          }

          std::optional<std::chrono::steady_clock::time_point> frame_timestamp;
          if (img) {
            frame_timestamp = img->frame_timestamp;
          }

          if (encode(ctx->frame_nr++, *pos->session, ctx->packets, ctx->channel_data, frame_timestamp, nullptr, nullptr, ctx->shutdown_event, bool(ctx->config.adaptive_bitrate))) {
            BOOST_LOG(error) << "Could not encode video packet"sv;
            ctx->shutdown_event->raise(true);

            continue;
          }

          pos->session->request_normal_frame();

          ++pos;
        })

        if (switch_display_event->peek()) {
          ec = platf::capture_e::reinit;
          return false;
        }

        return true;
      };

      auto pull_free_image_callback = [&img](std::shared_ptr<platf::img_t> &img_out) -> bool {
        img_out = img;
        img_out->frame_timestamp.reset();
        return true;
      };

      // capture() now takes its callbacks by value (WS2 capture-teardown UAF fix,
      // owner-session-runbook.md) -- std::move avoids an extra std::function copy;
      // neither lambda is used again after this call in the current loop iteration.
      auto status = disp->capture(std::move(push_captured_image_callback), std::move(pull_free_image_callback), &display_cursor);
      switch (status) {
        case platf::capture_e::reinit:
        case platf::capture_e::error:
        case platf::capture_e::ok:
        case platf::capture_e::timeout:
        case platf::capture_e::interrupted:
          return ec != platf::capture_e::ok ? ec : status;
      }
    }

    return encode_e::ok;
  }

  void captureThreadSync() {
    try {
      auto ref = capture_thread_sync.ref();

      std::vector<std::unique_ptr<sync_session_ctx_t>> synced_session_ctxs;

      auto &ctx = ref->encode_session_ctx_queue;
      auto lg = util::fail_guard([&]() {
        ctx.stop();

        for (auto &ctx : synced_session_ctxs) {
          ctx->shutdown_event->raise(true);
          ctx->join_event->raise(true);
        }

        for (auto &ctx : ctx.unsafe()) {
          ctx.shutdown_event->raise(true);
          ctx.join_event->raise(true);
        }
      });

      // Encoding and capture takes place on this thread
      platf::set_thread_name("video::capture_sync");
      platf::adjust_thread_priority(platf::thread_priority_e::high);

      std::vector<std::string> display_names;
      int display_p = -1;
      while (encode_run_sync(synced_session_ctxs, ctx, display_names, display_p) == encode_e::reinit) {}
    } catch (const std::exception &e) {
      BOOST_LOG(fatal) << "captureThreadSync terminating on exception: " << e.what();
      std::abort();
    } catch (...) {
      BOOST_LOG(fatal) << "captureThreadSync terminating on unknown exception";
      std::abort();
    }
  }

  void capture_async(
    safe::mail_t mail,
    config_t &config,
    void *channel_data
  ) {
    auto shutdown_event = mail->event<bool>(mail::shutdown);

    auto images = std::make_shared<img_event_t::element_type>();
    auto lg = util::fail_guard([&]() {
      images->stop();
      shutdown_event->raise(true);
    });

    auto ref = capture_thread_async.ref();
    if (!ref) {
      return;
    }

    ref->capture_ctx_queue->raise(capture_ctx_t {images, config});

    if (!ref->capture_ctx_queue->running()) {
      return;
    }

    int frame_nr = 1;

    // Backlog-plateau cure (2026-07-14, docs/design/2026-07-14-vt-backlog-reinit-cure.md):
    // per-stream state threaded through encode_run() by reference across rebuilds, exactly like
    // frame_nr above. cure_rebuild is in/out (see encode_run()'s doc comment); cure_disabled is
    // the one-way fail-safe kill-flag set if a cure-triggered rebuild ever fails to build.
    bool cure_rebuild = false;
    bool cure_disabled = false;

    auto touch_port_event = mail->event<input::touch_port_t>(mail::touch_port);
    auto hdr_event = mail->event<hdr_info_t>(mail::hdr);

    // Encoding takes place on this thread. Raised from `high` (QOS_CLASS_USER_INITIATED) to
    // `critical` (QOS_CLASS_USER_INTERACTIVE) per the latency program H1 finding: this is the
    // thread that actually calls into VideoToolbox (avcodec_send_frame), one QoS tier below the
    // C++ "capture" thread's critical badge even though it does the real latency-sensitive work.
    platf::adjust_thread_priority(platf::thread_priority_e::critical);

    while (!shutdown_event->peek() && images->running()) {
      // Wait for the main capture event when the display is being reinitialized
      if (ref->reinit_event.peek()) {
        std::this_thread::sleep_for(20ms);
        continue;
      }
      // Wait for the display to be ready
      std::shared_ptr<platf::display_t> display;
      {
        auto lg = ref->display_wp.lock();
        if (ref->display_wp->expired()) {
          continue;
        }

        display = ref->display_wp->lock();
      }

      auto &encoder = *chosen_encoder;
      if (config.adaptive_bitrate) config.bitrate = config.adaptive_bitrate->target();

      auto encode_device = make_encode_device(*display, encoder, config);
      if (!encode_device) {
        return;
      }

      // absolute mouse coordinates require that the dimensions of the screen are known
      touch_port_event->raise(make_port(display.get(), config));

      // Update client with our current HDR display state
      hdr_info_t hdr_info = std::make_unique<hdr_info_raw_t>(false);
      if (colorspace_is_hdr(encode_device->colorspace)) {
        if (display->get_hdr_metadata(hdr_info->metadata)) {
          hdr_info->enabled = true;
        } else {
          BOOST_LOG(error) << "Couldn't get display hdr metadata when colorspace selection indicates it should have one";
        }
      }
      hdr_event->raise(std::move(hdr_info));

      encode_run(
        frame_nr,
        mail,
        images,
        config,
        display,
        std::move(encode_device),
        ref->reinit_event,
        *ref->encoder_p,
        channel_data,
        cure_rebuild,
        cure_disabled
      );
    }
  }

  void capture(
    safe::mail_t mail,
    config_t config,
    void *channel_data
  ) {
    auto idr_events = mail->event<bool>(mail::idr);

    idr_events->raise(true);
    if (chosen_encoder->flags & PARALLEL_ENCODING) {
      capture_async(std::move(mail), config, channel_data);
    } else {
      safe::signal_t join_event;
      auto ref = capture_thread_sync.ref();
      ref->encode_session_ctx_queue.raise(sync_session_ctx_t {
        &join_event,
        mail->event<bool>(mail::shutdown),
        mail::man->queue<packet_t>(mail::video_packets),
        std::move(idr_events),
        mail->event<hdr_info_t>(mail::hdr),
        mail->event<input::touch_port_t>(mail::touch_port),
        config,
        1,
        channel_data,
      });

      // Wait for join signal
      join_event.view();
    }
  }

  enum validate_flag_e {
    VUI_PARAMS = 0x01,  ///< VUI parameters
  };

  int validate_config(std::shared_ptr<platf::display_t> disp, const encoder_t &encoder, const config_t &config) {
    auto encode_device = make_encode_device(*disp, encoder, config);
    if (!encode_device) {
      return -1;
    }

    auto session = make_encode_session(disp.get(), encoder, config, disp->width, disp->height, std::move(encode_device));
    if (!session) {
      return -1;
    }

    {
      // Image buffers are large, so we use a separate scope to free it immediately after convert()
      auto img = disp->alloc_img();
      if (!img || disp->dummy_img(img.get()) || session->convert(*img)) {
        return -1;
      }
    }

    session->request_idr_frame();

    auto packets = mail::man->queue<packet_t>(mail::video_packets);
    while (!packets->peek()) {
      if (encode(1, *session, packets, nullptr, {})) {
        return -1;
      }
    }

    auto packet = packets->pop();
    if (!packet->is_idr()) {
      BOOST_LOG(error) << "First packet type is not an IDR frame"sv;

      return -1;
    }

    int flag = 0;

    // This check only applies for H.264 and HEVC
    if (config.videoFormat <= 1) {
      if (auto packet_avcodec = dynamic_cast<packet_raw_avcodec *>(packet.get())) {
        if (cbs::validate_sps(packet_avcodec->av_packet, config.videoFormat ? AV_CODEC_ID_H265 : AV_CODEC_ID_H264)) {
          flag |= VUI_PARAMS;
        }
      } else {
        // Don't check it for non-avcodec encoders.
        flag |= VUI_PARAMS;
      }
    }

    return flag;
  }

  bool validate_encoder(encoder_t &encoder, bool expect_failure) {
    const auto output_name {display_device::map_output_name(config::video.output_name)};
    std::shared_ptr<platf::display_t> disp;

    BOOST_LOG(info) << "Trying encoder ["sv << encoder.name << ']';
    auto fg = util::fail_guard([&]() {
      BOOST_LOG(info) << "Encoder ["sv << encoder.name << "] failed"sv;
    });

    auto test_hevc = active_hevc_mode >= 2 || (active_hevc_mode == 0 && !(encoder.flags & H264_ONLY));
    auto test_av1 = active_av1_mode >= 2 || (active_av1_mode == 0 && !(encoder.flags & H264_ONLY));

    encoder.h264.capabilities.set();
    encoder.hevc.capabilities.set();
    encoder.av1.capabilities.set();

    // First, test encoder viability
    config_t config_max_ref_frames {1920, 1080, 60, 6000, 1000, 1, 1, 1, 0, 0, 0};
    config_t config_autoselect {1920, 1080, 60, 6000, 1000, 1, 0, 1, 0, 0, 0};

    // If the encoder isn't supported at all (not even H.264), bail early
    reset_display(disp, encoder.platform_formats->dev_type, output_name, config_autoselect);
    if (!disp) {
      return false;
    }
    if (!disp->is_codec_supported(encoder.h264.name, config_autoselect)) {
      fg.disable();
      BOOST_LOG(info) << "Encoder ["sv << encoder.name << "] is not supported on this GPU"sv;
      return false;
    }

    // If we're expecting failure, use the autoselect ref config first since that will always succeed
    // if the encoder is available.
    auto max_ref_frames_h264 = expect_failure ? -1 : validate_config(disp, encoder, config_max_ref_frames);
    auto autoselect_h264 = max_ref_frames_h264 >= 0 ? max_ref_frames_h264 : validate_config(disp, encoder, config_autoselect);
    if (autoselect_h264 < 0) {
      return false;
    } else if (expect_failure) {
      // We expected failure, but actually succeeded. Do the max_ref_frames probe we skipped.
      max_ref_frames_h264 = validate_config(disp, encoder, config_max_ref_frames);
    }

    std::vector<std::pair<validate_flag_e, encoder_t::flag_e>> packet_deficiencies {
      {VUI_PARAMS, encoder_t::VUI_PARAMETERS},
    };

    for (auto [validate_flag, encoder_flag] : packet_deficiencies) {
      encoder.h264[encoder_flag] = (max_ref_frames_h264 & validate_flag && autoselect_h264 & validate_flag);
    }

    encoder.h264[encoder_t::REF_FRAMES_RESTRICT] = max_ref_frames_h264 >= 0;
    encoder.h264[encoder_t::PASSED] = true;

    if (test_hevc) {
      config_max_ref_frames.videoFormat = 1;
      config_autoselect.videoFormat = 1;

      if (disp->is_codec_supported(encoder.hevc.name, config_autoselect)) {
        auto max_ref_frames_hevc = validate_config(disp, encoder, config_max_ref_frames);

        // If H.264 succeeded with max ref frames specified, assume that we can count on
        // HEVC to also succeed with max ref frames specified if HEVC is supported.
        auto autoselect_hevc = (max_ref_frames_hevc >= 0 || max_ref_frames_h264 >= 0) ?
                                 max_ref_frames_hevc :
                                 validate_config(disp, encoder, config_autoselect);

        for (auto [validate_flag, encoder_flag] : packet_deficiencies) {
          encoder.hevc[encoder_flag] = (max_ref_frames_hevc & validate_flag && autoselect_hevc & validate_flag);
        }

        encoder.hevc[encoder_t::REF_FRAMES_RESTRICT] = max_ref_frames_hevc >= 0;
        encoder.hevc[encoder_t::PASSED] = max_ref_frames_hevc >= 0 || autoselect_hevc >= 0;
      } else {
        BOOST_LOG(info) << "Encoder ["sv << encoder.hevc.name << "] is not supported on this GPU"sv;
        encoder.hevc.capabilities.reset();
      }
    } else {
      // Clear all cap bits for HEVC if we didn't probe it
      encoder.hevc.capabilities.reset();
    }

    if (test_av1) {
      config_max_ref_frames.videoFormat = 2;
      config_autoselect.videoFormat = 2;

      if (disp->is_codec_supported(encoder.av1.name, config_autoselect)) {
        auto max_ref_frames_av1 = validate_config(disp, encoder, config_max_ref_frames);

        // If H.264 succeeded with max ref frames specified, assume that we can count on
        // AV1 to also succeed with max ref frames specified if AV1 is supported.
        auto autoselect_av1 = (max_ref_frames_av1 >= 0 || max_ref_frames_h264 >= 0) ?
                                max_ref_frames_av1 :
                                validate_config(disp, encoder, config_autoselect);

        for (auto [validate_flag, encoder_flag] : packet_deficiencies) {
          encoder.av1[encoder_flag] = (max_ref_frames_av1 & validate_flag && autoselect_av1 & validate_flag);
        }

        encoder.av1[encoder_t::REF_FRAMES_RESTRICT] = max_ref_frames_av1 >= 0;
        encoder.av1[encoder_t::PASSED] = max_ref_frames_av1 >= 0 || autoselect_av1 >= 0;
      } else {
        BOOST_LOG(info) << "Encoder ["sv << encoder.av1.name << "] is not supported on this GPU"sv;
        encoder.av1.capabilities.reset();
      }
    } else {
      // Clear all cap bits for AV1 if we didn't probe it
      encoder.av1.capabilities.reset();
    }

    // Test HDR and YUV444 support
    {
      // H.264 is special because encoders may support YUV 4:4:4 without supporting 10-bit color depth
      if (encoder.flags & YUV444_SUPPORT) {
        config_t config_h264_yuv444 {1920, 1080, 60, 6000, 1000, 1, 0, 1, 0, 0, 1};
        encoder.h264[encoder_t::YUV444] = disp->is_codec_supported(encoder.h264.name, config_h264_yuv444) &&
                                          validate_config(disp, encoder, config_h264_yuv444) >= 0;
      } else {
        encoder.h264[encoder_t::YUV444] = false;
      }

      const config_t generic_hdr_config = {1920, 1080, 60, 6000, 1000, 1, 0, 3, 1, 1, 0};

      // Reset the display since we're switching from SDR to HDR
      reset_display(disp, encoder.platform_formats->dev_type, output_name, generic_hdr_config);
      if (!disp) {
        return false;
      }

      auto test_hdr_and_yuv444 = [&](auto &flag_map, auto video_format) {
        auto config = generic_hdr_config;
        config.videoFormat = video_format;

        if (!flag_map[encoder_t::PASSED]) {
          return;
        }

        auto encoder_codec_name = encoder.codec_from_config(config).name;

        // Test 4:4:4 HDR first. If 4:4:4 is supported, 4:2:0 should also be supported.
        config.chromaSamplingType = 1;
        if ((encoder.flags & YUV444_SUPPORT) &&
            disp->is_codec_supported(encoder_codec_name, config) &&
            validate_config(disp, encoder, config) >= 0) {
          flag_map[encoder_t::DYNAMIC_RANGE] = true;
          flag_map[encoder_t::YUV444] = true;
          return;
        } else {
          flag_map[encoder_t::YUV444] = false;
        }

        // Test 4:2:0 HDR
        config.chromaSamplingType = 0;
        if (disp->is_codec_supported(encoder_codec_name, config) &&
            validate_config(disp, encoder, config) >= 0) {
          flag_map[encoder_t::DYNAMIC_RANGE] = true;
        } else {
          flag_map[encoder_t::DYNAMIC_RANGE] = false;
        }
      };

      // HDR is not supported with H.264. Don't bother even trying it.
      encoder.h264[encoder_t::DYNAMIC_RANGE] = false;

      test_hdr_and_yuv444(encoder.hevc, 1);
      test_hdr_and_yuv444(encoder.av1, 2);
    }

    encoder.h264[encoder_t::VUI_PARAMETERS] = encoder.h264[encoder_t::VUI_PARAMETERS] && !config::sunshine.flags[config::flag::FORCE_VIDEO_HEADER_REPLACE];
    encoder.hevc[encoder_t::VUI_PARAMETERS] = encoder.hevc[encoder_t::VUI_PARAMETERS] && !config::sunshine.flags[config::flag::FORCE_VIDEO_HEADER_REPLACE];

    if (!encoder.h264[encoder_t::VUI_PARAMETERS]) {
      BOOST_LOG(warning) << encoder.name << ": h264 missing sps->vui parameters"sv;
    }
    if (encoder.hevc[encoder_t::PASSED] && !encoder.hevc[encoder_t::VUI_PARAMETERS]) {
      BOOST_LOG(warning) << encoder.name << ": hevc missing sps->vui parameters"sv;
    }

    fg.disable();
    return true;
  }

  int probe_encoders() {
    if (!allow_encoder_probing()) {
      // Error already logged
      return -1;
    }

    auto encoder_list = encoders;

    // If we already have a good encoder, check to see if another probe is required
    if (chosen_encoder && !(chosen_encoder->flags & ALWAYS_REPROBE) && !platf::needs_encoder_reenumeration()) {
      return 0;
    }

    // Restart encoder selection
    auto previous_encoder = chosen_encoder;
    chosen_encoder = nullptr;
    active_hevc_mode = config::video.hevc_mode;
    active_av1_mode = config::video.av1_mode;
    last_encoder_probe_supported_ref_frames_invalidation = false;

    auto adjust_encoder_constraints = [&](encoder_t *encoder) {
      // If we can't satisfy both the encoder and codec requirement, prefer the encoder over codec support
      if (active_hevc_mode == 3 && !encoder->hevc[encoder_t::DYNAMIC_RANGE]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support HEVC Main10 on this system"sv;
        active_hevc_mode = 0;
      } else if (active_hevc_mode == 2 && !encoder->hevc[encoder_t::PASSED]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support HEVC on this system"sv;
        active_hevc_mode = 0;
      }

      if (active_av1_mode == 3 && !encoder->av1[encoder_t::DYNAMIC_RANGE]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support AV1 Main10 on this system"sv;
        active_av1_mode = 0;
      } else if (active_av1_mode == 2 && !encoder->av1[encoder_t::PASSED]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support AV1 on this system"sv;
        active_av1_mode = 0;
      }
    };

    if (!config::video.encoder.empty()) {
      // If there is a specific encoder specified, use it if it passes validation
      KITTY_WHILE_LOOP(auto pos = std::begin(encoder_list), pos != std::end(encoder_list), {
        auto encoder = *pos;

        if (encoder->name == config::video.encoder) {
          // Remove the encoder from the list entirely if it fails validation
          if (!validate_encoder(*encoder, previous_encoder && previous_encoder != encoder)) {
            pos = encoder_list.erase(pos);
            break;
          }

          // We will return an encoder here even if it fails one of the codec requirements specified by the user
          adjust_encoder_constraints(encoder);

          chosen_encoder = encoder;
          break;
        }

        pos++;
      });

      if (chosen_encoder == nullptr) {
        BOOST_LOG(error) << "Couldn't find any working encoder matching ["sv << config::video.encoder << ']';
      }
    }

    BOOST_LOG(info) << "// Testing for available encoders, this may generate errors. You can safely ignore those errors. //"sv;

    // If we haven't found an encoder yet, but we want one with specific codec support, search for that now.
    if (chosen_encoder == nullptr && (active_hevc_mode >= 2 || active_av1_mode >= 2)) {
      KITTY_WHILE_LOOP(auto pos = std::begin(encoder_list), pos != std::end(encoder_list), {
        auto encoder = *pos;

        // Remove the encoder from the list entirely if it fails validation
        if (!validate_encoder(*encoder, previous_encoder && previous_encoder != encoder)) {
          pos = encoder_list.erase(pos);
          continue;
        }

        // Skip it if it doesn't support the specified codec at all
        if ((active_hevc_mode >= 2 && !encoder->hevc[encoder_t::PASSED]) ||
            (active_av1_mode >= 2 && !encoder->av1[encoder_t::PASSED])) {
          pos++;
          continue;
        }

        // Skip it if it doesn't support HDR on the specified codec
        if ((active_hevc_mode == 3 && !encoder->hevc[encoder_t::DYNAMIC_RANGE]) ||
            (active_av1_mode == 3 && !encoder->av1[encoder_t::DYNAMIC_RANGE])) {
          pos++;
          continue;
        }

        chosen_encoder = encoder;
        break;
      });

      if (chosen_encoder == nullptr) {
        BOOST_LOG(error) << "Couldn't find any working encoder that meets HEVC/AV1 requirements"sv;
      }
    }

    // If no encoder was specified or the specified encoder was unusable, keep trying
    // the remaining encoders until we find one that passes validation.
    if (chosen_encoder == nullptr) {
      KITTY_WHILE_LOOP(auto pos = std::begin(encoder_list), pos != std::end(encoder_list), {
        auto encoder = *pos;

        // If we've used a previous encoder and it's not this one, we expect this encoder to
        // fail to validate. It will use a slightly different order of checks to more quickly
        // eliminate failing encoders.
        if (!validate_encoder(*encoder, previous_encoder && previous_encoder != encoder)) {
          pos = encoder_list.erase(pos);
          continue;
        }

        // We will return an encoder here even if it fails one of the codec requirements specified by the user
        adjust_encoder_constraints(encoder);

        chosen_encoder = encoder;
        break;
      });
    }

    if (chosen_encoder == nullptr) {
      const auto output_name {display_device::map_output_name(config::video.output_name)};
      BOOST_LOG(fatal) << "Unable to find display or encoder during startup."sv;
      if (!config::video.adapter_name.empty() || !output_name.empty()) {
        BOOST_LOG(fatal) << "Please ensure your manually chosen GPU and monitor are connected and powered on."sv;
      } else {
        BOOST_LOG(fatal) << "Please check that a display is connected and powered on."sv;
      }
      return -1;
    }

    BOOST_LOG(info);
    BOOST_LOG(info) << "// Ignore any errors mentioned above, they are not relevant. //"sv;
    BOOST_LOG(info);

    auto &encoder = *chosen_encoder;

    last_encoder_probe_supported_ref_frames_invalidation = (encoder.flags & REF_FRAMES_INVALIDATION);
    last_encoder_probe_supported_yuv444_for_codec[0] = encoder.h264[encoder_t::PASSED] &&
                                                       encoder.h264[encoder_t::YUV444];
    last_encoder_probe_supported_yuv444_for_codec[1] = encoder.hevc[encoder_t::PASSED] &&
                                                       encoder.hevc[encoder_t::YUV444];
    last_encoder_probe_supported_yuv444_for_codec[2] = encoder.av1[encoder_t::PASSED] &&
                                                       encoder.av1[encoder_t::YUV444];

    BOOST_LOG(debug) << "------  h264 ------"sv;
    for (int x = 0; x < encoder_t::MAX_FLAGS; ++x) {
      auto flag = (encoder_t::flag_e) x;
      BOOST_LOG(debug) << encoder_t::from_flag(flag) << (encoder.h264[flag] ? ": supported"sv : ": unsupported"sv);
    }
    BOOST_LOG(debug) << "-------------------"sv;
    BOOST_LOG(info) << "Found H.264 encoder: "sv << encoder.h264.name << " ["sv << encoder.name << ']';

    if (encoder.hevc[encoder_t::PASSED]) {
      BOOST_LOG(debug) << "------  hevc ------"sv;
      for (int x = 0; x < encoder_t::MAX_FLAGS; ++x) {
        auto flag = (encoder_t::flag_e) x;
        BOOST_LOG(debug) << encoder_t::from_flag(flag) << (encoder.hevc[flag] ? ": supported"sv : ": unsupported"sv);
      }
      BOOST_LOG(debug) << "-------------------"sv;

      BOOST_LOG(info) << "Found HEVC encoder: "sv << encoder.hevc.name << " ["sv << encoder.name << ']';
    }

    if (encoder.av1[encoder_t::PASSED]) {
      BOOST_LOG(debug) << "------  av1 ------"sv;
      for (int x = 0; x < encoder_t::MAX_FLAGS; ++x) {
        auto flag = (encoder_t::flag_e) x;
        BOOST_LOG(debug) << encoder_t::from_flag(flag) << (encoder.av1[flag] ? ": supported"sv : ": unsupported"sv);
      }
      BOOST_LOG(debug) << "-------------------"sv;

      BOOST_LOG(info) << "Found AV1 encoder: "sv << encoder.av1.name << " ["sv << encoder.name << ']';
    }

    if (active_hevc_mode == 0) {
      active_hevc_mode = encoder.hevc[encoder_t::PASSED] ? (encoder.hevc[encoder_t::DYNAMIC_RANGE] ? 3 : 2) : 1;
    }

    if (active_av1_mode == 0) {
      active_av1_mode = encoder.av1[encoder_t::PASSED] ? (encoder.av1[encoder_t::DYNAMIC_RANGE] ? 3 : 2) : 1;
    }

    return 0;
  }

  // Linux only declaration
  typedef int (*vaapi_init_avcodec_hardware_input_buffer_fn)(platf::avcodec_encode_device_t *encode_device, AVBufferRef **hw_device_buf);

  util::Either<avcodec_buffer_t, int> vaapi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t hw_device_buf;

    // If an egl hwdevice
    if (encode_device->data) {
      if (((vaapi_init_avcodec_hardware_input_buffer_fn) encode_device->data)(encode_device, &hw_device_buf)) {
        return -1;
      }

      return hw_device_buf;
    }

    auto render_device = config::video.adapter_name.empty() ? nullptr : config::video.adapter_name.c_str();

    auto status = av_hwdevice_ctx_create(&hw_device_buf, AV_HWDEVICE_TYPE_VAAPI, render_device, nullptr, 0);
    if (status < 0) {
      char string[AV_ERROR_MAX_STRING_SIZE];
      BOOST_LOG(error) << "Failed to create a VAAPI device: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
      return -1;
    }

    return hw_device_buf;
  }

  util::Either<avcodec_buffer_t, int> cuda_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t hw_device_buf;

    auto status = av_hwdevice_ctx_create(&hw_device_buf, AV_HWDEVICE_TYPE_CUDA, nullptr, nullptr, 1 /* AV_CUDA_USE_PRIMARY_CONTEXT */);
    if (status < 0) {
      char string[AV_ERROR_MAX_STRING_SIZE];
      BOOST_LOG(error) << "Failed to create a CUDA device: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
      return -1;
    }

    return hw_device_buf;
  }

  util::Either<avcodec_buffer_t, int> vt_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t hw_device_buf;

    auto status = av_hwdevice_ctx_create(&hw_device_buf, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0);
    if (status < 0) {
      char string[AV_ERROR_MAX_STRING_SIZE];
      BOOST_LOG(error) << "Failed to create a VideoToolbox device: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
      return -1;
    }

    return hw_device_buf;
  }

#ifdef _WIN32
}

void do_nothing(void *) {
}

namespace video {
  util::Either<avcodec_buffer_t, int> dxgi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t ctx_buf {av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA)};
    auto ctx = (AVD3D11VADeviceContext *) ((AVHWDeviceContext *) ctx_buf->data)->hwctx;

    std::fill_n((std::uint8_t *) ctx, sizeof(AVD3D11VADeviceContext), 0);

    auto device = (ID3D11Device *) encode_device->data;

    device->AddRef();
    ctx->device = device;

    ctx->lock_ctx = (void *) 1;
    ctx->lock = do_nothing;
    ctx->unlock = do_nothing;

    auto err = av_hwdevice_ctx_init(ctx_buf.get());
    if (err) {
      char err_str[AV_ERROR_MAX_STRING_SIZE] {0};
      BOOST_LOG(error) << "Failed to create FFMpeg hardware device context: "sv << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, err);

      return err;
    }

    return ctx_buf;
  }
#endif

  int start_capture_async(capture_thread_async_ctx_t &capture_thread_ctx) {
    capture_thread_ctx.encoder_p = chosen_encoder;
    capture_thread_ctx.reinit_event.reset();

    capture_thread_ctx.capture_ctx_queue = std::make_shared<safe::queue_t<capture_ctx_t>>(30);

    capture_thread_ctx.capture_thread = std::thread {
      captureThread,
      capture_thread_ctx.capture_ctx_queue,
      std::ref(capture_thread_ctx.display_wp),
      std::ref(capture_thread_ctx.reinit_event),
      std::ref(*capture_thread_ctx.encoder_p)
    };

    return 0;
  }

  void end_capture_async(capture_thread_async_ctx_t &capture_thread_ctx) {
    capture_thread_ctx.capture_ctx_queue->stop();

    capture_thread_ctx.capture_thread.join();
  }

  int start_capture_sync(capture_thread_sync_ctx_t &ctx) {
    std::thread {&captureThreadSync}.detach();
    return 0;
  }

  void end_capture_sync(capture_thread_sync_ctx_t &ctx) {
  }

  platf::mem_type_e map_base_dev_type(AVHWDeviceType type) {
    switch (type) {
      case AV_HWDEVICE_TYPE_D3D11VA:
        return platf::mem_type_e::dxgi;
      case AV_HWDEVICE_TYPE_VAAPI:
        return platf::mem_type_e::vaapi;
      case AV_HWDEVICE_TYPE_CUDA:
        return platf::mem_type_e::cuda;
      case AV_HWDEVICE_TYPE_NONE:
        return platf::mem_type_e::system;
      case AV_HWDEVICE_TYPE_VIDEOTOOLBOX:
        return platf::mem_type_e::videotoolbox;
      default:
        return platf::mem_type_e::unknown;
    }

    return platf::mem_type_e::unknown;
  }

  platf::pix_fmt_e map_pix_fmt(AVPixelFormat fmt) {
    switch (fmt) {
      case AV_PIX_FMT_VUYX:
        return platf::pix_fmt_e::ayuv;
      case AV_PIX_FMT_XV30:
        return platf::pix_fmt_e::y410;
      case AV_PIX_FMT_YUV420P10:
        return platf::pix_fmt_e::yuv420p10;
      case AV_PIX_FMT_YUV420P:
        return platf::pix_fmt_e::yuv420p;
      case AV_PIX_FMT_NV12:
        return platf::pix_fmt_e::nv12;
      case AV_PIX_FMT_P010:
        return platf::pix_fmt_e::p010;
      default:
        return platf::pix_fmt_e::unknown;
    }

    return platf::pix_fmt_e::unknown;
  }

}  // namespace video
