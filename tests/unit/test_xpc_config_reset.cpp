#ifdef __APPLE__
  #include <atomic>
  #include <filesystem>
  #include <fstream>
  #include <gtest/gtest.h>
  #include <nlohmann/json.hpp>
  #include <src/config.h>
  #include <src/config_validate.h>
  #include <src/file_handler.h>
  #include <src/platform/macos/xpc_control.h>
  #include <src/utility.h>
  #include <string>
  #include <thread>

namespace {
  class XpcConfigReset: public testing::Test {
  protected:
    std::string original;
    std::filesystem::path directory;
    void SetUp() override {
      original = config::sunshine.config_file;
      const auto schema = std::filesystem::path {SUNSHINE_TEST_BIN_DIR} / "src_assets/common/assets/web/config_schema.json";
      ASSERT_TRUE(std::filesystem::is_regular_file(schema)) << "Missing CMake schema fixture: " << schema;
      ASSERT_TRUE(config_validate::load_schema(schema.string()).has_value()) << "Invalid CMake schema fixture: " << schema;
      directory = std::filesystem::path(testing::TempDir()) / ("skylight-xpc-reset-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
      std::filesystem::create_directories(directory);
      config::sunshine.config_file = (directory / "sunshine.conf").string();
    }
    void TearDown() override {
      config::sunshine.config_file = original;
      if (!directory.empty()) {
        std::filesystem::remove_all(directory);
      }
    }
    void write(const std::string &text) { std::ofstream(config::sunshine.config_file) << text; }
    std::string read() { return file_handler::read_file(config::sunshine.config_file.c_str()); }
  };
}

TEST_F(XpcConfigReset, ClearSupportedOverridesRemovesDuplicatesAndPreservesOtherSettings) {
  for (const std::string key : {"sunshine_name", "output_name", "external_ip"}) {
    write("# Keep this comment\n" + key + " = old\n" + key + " = duplicate\n" + key + "_extra = retain\nport = 47989\n");
    ASSERT_EQ(platf::macos::set_config_value_for_tests(key, ""), "");
    const auto text = read();
    const auto parsed = config::parse_config(text);
    EXPECT_EQ(parsed.count(key), 0u); // startup now uses its real default
    ASSERT_TRUE(parsed.contains(key + "_extra"));
    EXPECT_EQ(parsed.at(key + "_extra"), "retain");
    ASSERT_TRUE(parsed.contains("port"));
    EXPECT_EQ(parsed.at("port"), "47989");
    EXPECT_NE(text.find("# Keep this comment"), std::string::npos);
  }
}

TEST_F(XpcConfigReset, SnapshotRestoreIsValidatedAtomicAndKeepsProtectedUnknownData) {
  write("# keep\nencoder = videotoolbox\nport = 48000\npkey = /private/key\ncustom_future_key = preserve\n");
  const auto before = nlohmann::json::parse(platf::macos::configuration_state_for_tests());
  const auto revision = before.at("revision").get<std::string>();
  auto invalid = nlohmann::json {{"encoder", "software"}, {"port", "invalid"}};
  const auto original = read();
  EXPECT_FALSE(platf::macos::restore_configuration_for_tests(invalid.dump(), revision).empty());
  EXPECT_EQ(read(), original);
  EXPECT_FALSE(platf::macos::restore_configuration_for_tests("{\"pkey\":\"elsewhere\"}", revision).empty());
  EXPECT_EQ(read(), original);
  ASSERT_EQ(platf::macos::restore_configuration_for_tests("{\"encoder\":\"software\"}", revision), "");
  const auto restored = config::parse_config(read());
  EXPECT_EQ(restored.at("encoder"), "software");
  EXPECT_FALSE(restored.contains("port")); // absence in the snapshot restores default
  EXPECT_EQ(restored.at("pkey"), "/private/key");
  EXPECT_EQ(restored.at("custom_future_key"), "preserve");
  const auto snapshots = directory / "settings-snapshots";
  ASSERT_TRUE(std::filesystem::is_directory(snapshots));
  ASSERT_EQ(std::distance(std::filesystem::directory_iterator(snapshots), std::filesystem::directory_iterator()), 1);
  for (const auto &file : std::filesystem::directory_iterator(snapshots)) {
    const auto backup = nlohmann::json::parse(file_handler::read_file(file.path().string().c_str()));
    EXPECT_EQ(backup.at("name"), "Before restore");
    EXPECT_EQ(backup["values"]["port"], "48000");
    EXPECT_FALSE(backup["values"].contains("pkey"));
    EXPECT_FALSE(backup["values"].contains("custom_future_key"));
  }
  const auto after = read();
  EXPECT_FALSE(platf::macos::restore_configuration_for_tests("{}", revision).empty());
  EXPECT_EQ(read(), after); // a stale preview cannot overwrite a later change
}

TEST_F(XpcConfigReset, ConflictResolutionUsesFileRevisionAndCanRestoreDefaultWithoutResettingOtherKeys) {
  write("port = 48000\nencoder = software\ncustom = keep\n");
  const auto revision = nlohmann::json::parse(platf::macos::configuration_state_for_tests())["revision"].get<std::string>();
  EXPECT_FALSE(platf::macos::resolve_configuration_value_for_tests("port", "null", "stale").empty());
  ASSERT_EQ(platf::macos::resolve_configuration_value_for_tests("port", "null", revision), "");
  const auto values = config::parse_config(read());
  EXPECT_FALSE(values.contains("port"));
  EXPECT_EQ(values.at("encoder"), "software");
  EXPECT_EQ(values.at("custom"), "keep");
  EXPECT_TRUE(platf::macos::product_protocol_contract_for_tests());
}

TEST_F(XpcConfigReset, FileRestoreReportsActualLiveValuesWithoutPretendingTheyWereApplied) {
  const auto original_virtual_display = config::video.virtual_display;
  const auto original_quit = config::sunshine.quit_app_on_disconnect;
  const auto original_fps = config::video.minimum_fps_target;
  const auto original_launch = platf::macos::set_running_configuration_for_tests(
    "virtual_display = disabled\nquit_app_on_disconnect = enabled\nminimum_fps_target = 30\n");
  auto restore_runtime = util::fail_guard([&] {
    platf::macos::set_running_configuration_for_tests(original_launch);
    config::video.virtual_display = original_virtual_display;
    config::sunshine.quit_app_on_disconnect = original_quit;
    config::video.minimum_fps_target = original_fps;
  });
  config::video.virtual_display = "enabled";
  config::sunshine.quit_app_on_disconnect = false;
  config::video.minimum_fps_target = 0;
  // Model acknowledged live setters after startup, then restoring the launch-time setup.
  write("virtual_display = enabled\nquit_app_on_disconnect = disabled\nminimum_fps_target = 0\ncustom = keep\n");
  const auto before = nlohmann::json::parse(platf::macos::configuration_state_for_tests());
  const auto error = platf::macos::restore_configuration_for_tests(
    R"({"virtual_display":"disabled","quit_app_on_disconnect":"enabled","minimum_fps_target":"30"})",
    before["revision"].get<std::string>());
  const auto after = nlohmann::json::parse(platf::macos::configuration_state_for_tests());
  // Runtime values are inert test-process config only; the guard restores them on all exits.
  ASSERT_EQ(error, "");
  EXPECT_EQ(after["values"]["virtual_display"], "disabled");
  EXPECT_EQ(after["runningValues"]["virtual_display"], "enabled");
  EXPECT_EQ(after["values"]["quit_app_on_disconnect"], "enabled");
  EXPECT_EQ(after["runningValues"]["quit_app_on_disconnect"], "disabled");
  EXPECT_EQ(after["values"]["minimum_fps_target"], "30");
  ASSERT_TRUE(after["runningValues"]["minimum_fps_target"].is_string());
  EXPECT_EQ(std::stod(after["runningValues"]["minimum_fps_target"].get<std::string>()), 0);
  EXPECT_EQ(after["values"]["custom"], "keep");
}

TEST_F(XpcConfigReset, BackupFailureCannotPublishHalfRestoredConfiguration) {
  write("encoder = videotoolbox\nport = 48000\n");
  const auto original = read();
  const auto revision = nlohmann::json::parse(platf::macos::configuration_state_for_tests())["revision"].get<std::string>();
  std::ofstream(directory / "settings-snapshots") << "protected unrelated file";
  EXPECT_FALSE(platf::macos::restore_configuration_for_tests("{\"encoder\":\"software\"}", revision).empty());
  EXPECT_EQ(read(), original);
}

TEST_F(XpcConfigReset, UnreadableConfigurationIsUnavailableNotAnEmptySettingsProfile) {
  config::sunshine.config_file = (directory / "does-not-exist.conf").string();
  EXPECT_TRUE(platf::macos::configuration_state_for_tests().empty());
  EXPECT_FALSE(platf::macos::restore_configuration_for_tests("{}", "old-revision").empty());
  EXPECT_FALSE(std::filesystem::exists(config::sunshine.config_file));
}

TEST_F(XpcConfigReset, EmptyNonResettableAndUnknownSettingsAreRejectedWithoutWriting) {
  const std::string baseline = "port = 47989\nencoder = videotoolbox\n";
  for (const std::string key : {"port", "encoder", "keyboard", "global_prep_cmd", "unknown_key"}) {
    write(baseline);
    EXPECT_FALSE(platf::macos::set_config_value_for_tests(key, "").empty()) << key;
    EXPECT_EQ(read(), baseline);
  }
}

TEST_F(XpcConfigReset, NonemptyWriteRemainsValidatedAndResetWriteFailureIsReported) {
  write("port = 47989\n");
  EXPECT_FALSE(platf::macos::set_config_value_for_tests("port", "invalid").empty());
  EXPECT_EQ(read(), "port = 47989\n");
  ASSERT_EQ(platf::macos::set_config_value_for_tests("sunshine_name", "Test Mac"), "");
  const auto values = config::parse_config(read());
  ASSERT_TRUE(values.contains("sunshine_name"));
  EXPECT_EQ(values.at("sunshine_name"), "Test Mac");
  // A nonexistent parent is an isolated, deterministic write failure; no permission changes.
  config::sunshine.config_file = (directory / "missing" / "sunshine.conf").string();
  EXPECT_FALSE(platf::macos::set_config_value_for_tests("sunshine_name", "").empty());
}

TEST_F(XpcConfigReset, CodecPairUpdatesAllDuplicatesPreservingUnrelatedBytesAndMode) {
  const std::string original = "# retain\nhevc_mode = 3\n av1_mode = 1\nhevc_mode = 1\nav1_mode=3\nhevc_mode_extra = retain\nport = 47989";
  write(original);
  const auto mode = std::filesystem::perms::owner_read | std::filesystem::perms::owner_write;
  std::filesystem::permissions(config::sunshine.config_file, mode);
  ASSERT_EQ(platf::macos::set_codec_policy_for_tests("2", "0"), "");
  EXPECT_EQ(read(), "# retain\nhevc_mode = 2\nav1_mode = 0\nhevc_mode = 2\nav1_mode = 0\nhevc_mode_extra = retain\nport = 47989");
  EXPECT_EQ(std::filesystem::status(config::sunshine.config_file).permissions(), mode);
  auto values = config::parse_config(read());
  EXPECT_EQ(values.at("hevc_mode"), "2");
  EXPECT_EQ(values.at("av1_mode"), "0");
  ASSERT_EQ(platf::macos::set_codec_policy_for_tests("0", "0"), "");
  values = config::parse_config(read());
  EXPECT_EQ(values.at("hevc_mode"), "0");
  EXPECT_EQ(values.at("av1_mode"), "0");
}

TEST_F(XpcConfigReset, InvalidCodecHalfNeverWritesEitherKeyOrChangesRuntimePolicy) {
  const std::string original = "hevc_mode = 2\nav1_mode = 1\nport = 47989\n";
  const auto runtime_hevc = config::video.hevc_mode;
  const auto runtime_av1 = config::video.av1_mode;
  for (const auto &invalid : {"", "4", "-1", "2x", "0\nport = 5"}) {
    for (bool first : {true, false}) {
      write(original);
      EXPECT_FALSE(platf::macos::set_codec_policy_for_tests(first ? invalid : "0", first ? "2" : invalid).empty());
      EXPECT_EQ(read(), original);
    }
  }
  EXPECT_EQ(config::video.hevc_mode, runtime_hevc);
  EXPECT_EQ(config::video.av1_mode, runtime_av1);
}

TEST_F(XpcConfigReset, CodecPairCreatesAbsentConfigAndReportsWriteAndReadFailures) {
  ASSERT_EQ(platf::macos::set_codec_policy_for_tests("1", "2"), "");
  EXPECT_EQ(read(), "hevc_mode = 1\nav1_mode = 2\n");
  const auto saved_path = config::sunshine.config_file;
  config::sunshine.config_file = (directory / "missing" / "sunshine.conf").string();
  EXPECT_FALSE(platf::macos::set_codec_policy_for_tests("2", "1").empty());
  EXPECT_FALSE(std::filesystem::exists(config::sunshine.config_file));
  // An existing directory is a deterministic read failure without modifying permissions.
  config::sunshine.config_file = directory.string();
  EXPECT_FALSE(platf::macos::set_codec_policy_for_tests("2", "1").empty());
  config::sunshine.config_file = saved_path;
  EXPECT_EQ(read(), "hevc_mode = 1\nav1_mode = 2\n");
}

TEST_F(XpcConfigReset, ConcurrentReadersObserveOnlyCompleteCodecTransitions) {
  write("hevc_mode = 2\nav1_mode = 1\n");
  std::atomic<bool> stop = false;
  std::atomic<bool> mixed = false;
  std::atomic<unsigned> reads = 0;
  const auto path = config::sunshine.config_file;
  std::thread reader([&] {
    while (!stop.load()) {
      const auto snapshot = file_handler::read_file(path.c_str());
      if (snapshot != "hevc_mode = 2\nav1_mode = 1\n" && snapshot != "hevc_mode = 1\nav1_mode = 2\n") {
        mixed = true;
      }
      ++reads;
    }
  });
  while (reads.load() == 0) {
    std::this_thread::yield();
  }
  for (int i = 0; i < 50; ++i) {
    EXPECT_EQ(platf::macos::set_codec_policy_for_tests(i % 2 ? "2" : "1", i % 2 ? "1" : "2"), "");
  }
  stop = true;
  reader.join();
  EXPECT_FALSE(mixed.load());
  EXPECT_GT(reads.load(), 0u);
}

TEST(XpcCaptureDisplays, ImplementsMirroredSelectorsAndReturnsNamedStringIdsWithoutCreatingDisplay) {
  EXPECT_TRUE(platf::macos::codec_display_protocol_contract_for_tests());
  const auto displays = nlohmann::json::parse(platf::macos::capture_displays_for_tests());
  ASSERT_TRUE(displays.is_array());
  for (const auto &display : displays) {
    ASSERT_TRUE(display.at("id").is_string());
    ASSERT_TRUE(display.at("name").is_string());
    EXPECT_FALSE(display.at("id").get<std::string>().empty());
    EXPECT_FALSE(display.at("name").get<std::string>().empty());
  }
}

TEST(XpcCaptureDisplays, WorkerEnumerationCompletesWhileMainRunLoopPumps) {
  const auto snapshot = platf::macos::capture_displays_on_worker_for_tests(std::chrono::seconds(2));
  ASSERT_FALSE(snapshot.empty()) << "Background enumerator did not complete within its main-run-loop deadline";
  const auto displays = nlohmann::json::parse(snapshot);
  ASSERT_TRUE(displays.is_array());
  for (const auto &display : displays) {
    ASSERT_TRUE(display.at("id").is_string());
    ASSERT_TRUE(display.at("name").is_string());
  }
}
#endif
