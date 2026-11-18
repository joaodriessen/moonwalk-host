/**
 * @file tests/unit/test_confighttp.cpp
 * @brief Test the pure-logic pieces of src/confighttp.cpp that don't require a live
 * Simple-Web-Server Request/Response (which is impractical to construct in a unit test).
 *
 * confighttp.cpp is compiled directly into test_sunshine (see tests/CMakeLists.txt's
 * SUNSHINE_SOURCES glob), and extract_authority()/is_same_origin_impl()/
 * would_inject_config_line() have external linkage (declared inside `namespace confighttp`, not
 * an anonymous namespace, not `static`) but are not exposed in confighttp.h -- so a forward
 * declaration here is enough for the linker to resolve them against confighttp.cpp's real
 * definitions. No header change needed. Same story for the saveApp/unpair/savePassword payload
 * validators added alongside them (item C, docs/design/config-schema-ssot.md's sibling brief).
 */
#include "../tests_common.h"

#include <string>

#include <nlohmann/json.hpp>

namespace confighttp {
  std::string extract_authority(const std::string &url);
  bool is_same_origin_impl(const std::string *origin, const std::string *referer, const std::string *host);
  bool would_inject_config_line(const std::string &key, const std::string &serialized_value);
  bool validate_app_payload(const nlohmann::json &input_tree, std::string &error);
  bool validate_unpair_payload(const nlohmann::json &input_tree, std::string &error);
  bool validate_password_payload_lengths(const nlohmann::json &input_tree, std::string &error);
}  // namespace confighttp

// ---------------------------------------------------------------------
// extract_authority() -- strips scheme and, for Referer-shaped URLs, path/query/fragment
// ---------------------------------------------------------------------

TEST(ConfigHttpExtractAuthority, OriginShapeNoPath) {
  EXPECT_EQ(confighttp::extract_authority("https://192.168.1.5:47990"), "192.168.1.5:47990");
}

TEST(ConfigHttpExtractAuthority, RefererShapeWithPath) {
  EXPECT_EQ(confighttp::extract_authority("https://192.168.1.5:47990/config?tab=general#x"), "192.168.1.5:47990");
}

TEST(ConfigHttpExtractAuthority, HttpScheme) {
  EXPECT_EQ(confighttp::extract_authority("http://localhost:8080/pin"), "localhost:8080");
}

TEST(ConfigHttpExtractAuthority, NoSchemePassesThroughVerbatim) {
  // Defensive: a malformed/schemeless value just passes through rather than crashing.
  EXPECT_EQ(confighttp::extract_authority("localhost:47990"), "localhost:47990");
}

// ---------------------------------------------------------------------
// is_same_origin_impl() -- CSRF same-origin guard (wave-A item 6)
//
// Mirrors upstream Sunshine's own validate_csrf_token() decision tree (see the doc comment on
// is_same_origin() in confighttp.cpp): absent Origin/Referer -> allow; present-and-matching ->
// allow; present-but-mismatched -> reject.
// ---------------------------------------------------------------------

TEST(ConfigHttpIsSameOrigin, AbsentOriginAndRefererAllowed) {
  EXPECT_TRUE(confighttp::is_same_origin_impl(nullptr, nullptr, nullptr));
}

TEST(ConfigHttpIsSameOrigin, AbsentOriginAndRefererAllowedEvenWithHostPresent) {
  std::string host = "192.168.1.5:47990";
  EXPECT_TRUE(confighttp::is_same_origin_impl(nullptr, nullptr, &host));
}

TEST(ConfigHttpIsSameOrigin, MatchingOriginAllowed) {
  std::string origin = "https://192.168.1.5:47990";
  std::string host = "192.168.1.5:47990";
  EXPECT_TRUE(confighttp::is_same_origin_impl(&origin, nullptr, &host));
}

TEST(ConfigHttpIsSameOrigin, MismatchedOriginRejected) {
  std::string origin = "https://evil.example.com";
  std::string host = "192.168.1.5:47990";
  EXPECT_FALSE(confighttp::is_same_origin_impl(&origin, nullptr, &host));
}

TEST(ConfigHttpIsSameOrigin, MatchingRefererFallbackAllowed) {
  std::string referer = "https://192.168.1.5:47990/config";
  std::string host = "192.168.1.5:47990";
  EXPECT_TRUE(confighttp::is_same_origin_impl(nullptr, &referer, &host));
}

TEST(ConfigHttpIsSameOrigin, MismatchedRefererRejected) {
  std::string referer = "https://evil.example.com/steal";
  std::string host = "192.168.1.5:47990";
  EXPECT_FALSE(confighttp::is_same_origin_impl(nullptr, &referer, &host));
}

TEST(ConfigHttpIsSameOrigin, OriginPreferredOverRefererWhenBothPresent) {
  std::string origin = "https://192.168.1.5:47990";
  std::string referer = "https://evil.example.com/steal";
  std::string host = "192.168.1.5:47990";
  EXPECT_TRUE(confighttp::is_same_origin_impl(&origin, &referer, &host));
}

TEST(ConfigHttpIsSameOrigin, PresentOriginButNoHostFailsClosed) {
  std::string origin = "https://192.168.1.5:47990";
  EXPECT_FALSE(confighttp::is_same_origin_impl(&origin, nullptr, nullptr));
}

TEST(ConfigHttpIsSameOrigin, EmptyOriginStringTreatedAsAbsent) {
  std::string origin = "";
  std::string host = "192.168.1.5:47990";
  EXPECT_TRUE(confighttp::is_same_origin_impl(&origin, nullptr, &host));
}

// ---------------------------------------------------------------------
// would_inject_config_line() -- type-agnostic write-site newline guard
//
// Judge follow-up to wave-A item 1: config_validate::validate_known_option()'s newline check is
// gated on schema type == string/path/enum. Known options of type list/object/map (e.g. the real
// schema's global_prep_cmd, dd_mode_remapping, keybindings) fall through that guard's
// "pass-through unchecked" tail, so a posted value like the one below would previously reach
// saveConfig()'s write loop unchecked and inject a second sunshine.conf directive on reload. This
// is the exact repro payload from the judge's report.
// ---------------------------------------------------------------------

TEST(ConfigHttpWouldInjectConfigLine, JudgeRepoPayloadGlobalPrepCmdNewlineDetected) {
  EXPECT_TRUE(confighttp::would_inject_config_line("global_prep_cmd", "x\nsome_key = value"));
}

TEST(ConfigHttpWouldInjectConfigLine, CarriageReturnInValueDetected) {
  EXPECT_TRUE(confighttp::would_inject_config_line("global_prep_cmd", "x\rsome_key = value"));
}

TEST(ConfigHttpWouldInjectConfigLine, NewlineInKeyItselfDetected) {
  EXPECT_TRUE(confighttp::would_inject_config_line("foo\nglobal_prep_cmd", "[{\"do\":\"evil\"}]"));
}

TEST(ConfigHttpWouldInjectConfigLine, CleanListValueNotFlagged) {
  // Sanity: a normal global_prep_cmd-shaped JSON-array-dumped-to-string value (no embedded
  // newline) must not false-positive.
  EXPECT_FALSE(confighttp::would_inject_config_line("global_prep_cmd", R"([{"do":"something","undo":""}])"));
}

TEST(ConfigHttpWouldInjectConfigLine, CleanStringValueNotFlagged) {
  EXPECT_FALSE(confighttp::would_inject_config_line("encoder", "software"));
}

// ---------------------------------------------------------------------
// validate_app_payload() -- saveApp() input validation (item C,
// docs/design/design-modernization.md section "C -- right-size input validation")
// ---------------------------------------------------------------------

TEST(ConfigHttpValidateAppPayload, TypicalWebUiPayloadAccepted) {
  // Shape produced by apps.html's newApp()/save() for a brand-new app.
  auto input = nlohmann::json::parse(R"({
    "name": "Hello, World!",
    "output": "",
    "cmd": "",
    "index": -1,
    "exclude-global-prep-cmd": false,
    "elevated": false,
    "auto-detach": true,
    "wait-all": true,
    "exit-timeout": 5,
    "prep-cmd": [],
    "detached": [],
    "image-path": ""
  })");
  std::string error;
  EXPECT_TRUE(confighttp::validate_app_payload(input, error)) << error;
}

TEST(ConfigHttpValidateAppPayload, PayloadWithPrepCmdAndDetachedAccepted) {
  auto input = nlohmann::json::parse(R"({
    "name": "Steam",
    "cmd": "steam.exe",
    "index": -1,
    "prep-cmd": [
      {"do": "start service", "undo": "stop service", "elevated": false}
    ],
    "detached": ["helper.exe"]
  })");
  std::string error;
  EXPECT_TRUE(confighttp::validate_app_payload(input, error)) << error;
}

TEST(ConfigHttpValidateAppPayload, MissingNameRejected) {
  auto input = nlohmann::json::parse(R"({"cmd": "steam.exe", "index": -1})");
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
  EXPECT_FALSE(error.empty());
}

TEST(ConfigHttpValidateAppPayload, EmptyNameRejected) {
  auto input = nlohmann::json::parse(R"({"name": "", "index": -1})");
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, NonStringNameRejected) {
  auto input = nlohmann::json::parse(R"({"name": 1234, "index": -1})");
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, EmbeddedNewlineInCmdRejected) {
  // Same injection class would_inject_config_line() already closes on the sunshine.conf write
  // path -- here the target is a launch/prep command instead of a config directive.
  nlohmann::json input;
  input["name"] = "Evil";
  input["cmd"] = "legit.exe\nglobal_prep_cmd = [{\"do\":\"rm -rf /\"}]";
  input["index"] = -1;
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, EmbeddedNewlineInPrepCmdRejected) {
  nlohmann::json input;
  input["name"] = "Evil";
  input["index"] = -1;
  input["prep-cmd"] = nlohmann::json::array({
    {{"do", "start\nglobal_prep_cmd = evil"}, {"undo", ""}, {"elevated", false}}
  });
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, EmbeddedNewlineInDetachedEntryRejected) {
  nlohmann::json input;
  input["name"] = "Evil";
  input["index"] = -1;
  input["detached"] = nlohmann::json::array({"helper.exe\nglobal_prep_cmd = evil"});
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, OversizedStringFieldRejected) {
  nlohmann::json input;
  input["name"] = std::string(70000, 'a');
  input["index"] = -1;
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, NonArrayPrepCmdRejected) {
  nlohmann::json input;
  input["name"] = "App";
  input["index"] = -1;
  input["prep-cmd"] = "not-an-array";
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, NonArrayDetachedRejected) {
  nlohmann::json input;
  input["name"] = "App";
  input["index"] = -1;
  input["detached"] = "not-an-array";
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, NonStringDetachedEntryRejected) {
  nlohmann::json input;
  input["name"] = "App";
  input["index"] = -1;
  input["detached"] = nlohmann::json::array({123});
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

TEST(ConfigHttpValidateAppPayload, NonObjectBodyRejected) {
  auto input = nlohmann::json::array({1, 2, 3});
  std::string error;
  EXPECT_FALSE(confighttp::validate_app_payload(input, error));
}

// ---------------------------------------------------------------------
// validate_unpair_payload() -- unpair() input validation (item C)
// ---------------------------------------------------------------------

TEST(ConfigHttpValidateUnpairPayload, TypicalWebUiPayloadAccepted) {
  auto input = nlohmann::json::parse(R"({"uuid": "1234"})");
  std::string error;
  EXPECT_TRUE(confighttp::validate_unpair_payload(input, error)) << error;
}

TEST(ConfigHttpValidateUnpairPayload, RealUuidShapeAccepted) {
  auto input = nlohmann::json::parse(R"({"uuid": "4D7BB2DD-5704-A405-B41C-891A022932E1"})");
  std::string error;
  EXPECT_TRUE(confighttp::validate_unpair_payload(input, error)) << error;
}

TEST(ConfigHttpValidateUnpairPayload, MissingUuidRejected) {
  auto input = nlohmann::json::parse(R"({})");
  std::string error;
  EXPECT_FALSE(confighttp::validate_unpair_payload(input, error));
}

TEST(ConfigHttpValidateUnpairPayload, EmptyUuidRejected) {
  auto input = nlohmann::json::parse(R"({"uuid": ""})");
  std::string error;
  EXPECT_FALSE(confighttp::validate_unpair_payload(input, error));
}

TEST(ConfigHttpValidateUnpairPayload, NonStringUuidRejected) {
  auto input = nlohmann::json::parse(R"({"uuid": 1234})");
  std::string error;
  EXPECT_FALSE(confighttp::validate_unpair_payload(input, error));
}

TEST(ConfigHttpValidateUnpairPayload, EmbeddedNewlineInUuidRejected) {
  nlohmann::json input;
  input["uuid"] = "1234\nsome_key = value";
  std::string error;
  EXPECT_FALSE(confighttp::validate_unpair_payload(input, error));
}

TEST(ConfigHttpValidateUnpairPayload, OversizedUuidRejected) {
  nlohmann::json input;
  input["uuid"] = std::string(300, '1');
  std::string error;
  EXPECT_FALSE(confighttp::validate_unpair_payload(input, error));
}

// ---------------------------------------------------------------------
// validate_password_payload_lengths() -- savePassword() input validation (item C)
//
// savePassword() itself still owns presence/mismatch semantics (current-credential check,
// new/confirm match, username fallback) -- this validator only adds the missing type/size bound,
// so these tests cover exactly that surface, not the full handler.
// ---------------------------------------------------------------------

TEST(ConfigHttpValidatePasswordPayloadLengths, TypicalWebUiPayloadAccepted) {
  auto input = nlohmann::json::parse(R"({
    "currentUsername": "admin",
    "currentPassword": "admin",
    "newUsername": "admin",
    "newPassword": "newpass123",
    "confirmNewPassword": "newpass123"
  })");
  std::string error;
  EXPECT_TRUE(confighttp::validate_password_payload_lengths(input, error)) << error;
}

TEST(ConfigHttpValidatePasswordPayloadLengths, FirstRunPayloadWithNoCurrentCredsAccepted) {
  // welcome.html's first-run flow posts only newUsername/newPassword/confirmNewPassword.
  auto input = nlohmann::json::parse(R"({
    "newUsername": "admin",
    "newPassword": "newpass123",
    "confirmNewPassword": "newpass123"
  })");
  std::string error;
  EXPECT_TRUE(confighttp::validate_password_payload_lengths(input, error)) << error;
}

TEST(ConfigHttpValidatePasswordPayloadLengths, MissingFieldsAccepted) {
  // Presence/emptiness is savePassword()'s own job (Invalid Username / Password Mismatch) --
  // this validator must not reject a payload just because a field is absent.
  auto input = nlohmann::json::parse(R"({})");
  std::string error;
  EXPECT_TRUE(confighttp::validate_password_payload_lengths(input, error)) << error;
}

TEST(ConfigHttpValidatePasswordPayloadLengths, NonStringFieldRejected) {
  nlohmann::json input;
  input["newPassword"] = 12345;
  std::string error;
  EXPECT_FALSE(confighttp::validate_password_payload_lengths(input, error));
}

TEST(ConfigHttpValidatePasswordPayloadLengths, OversizedNewPasswordRejected) {
  nlohmann::json input;
  input["newPassword"] = std::string(2000, 'x');
  std::string error;
  EXPECT_FALSE(confighttp::validate_password_payload_lengths(input, error));
}

TEST(ConfigHttpValidatePasswordPayloadLengths, MaxLengthBoundaryAccepted) {
  nlohmann::json input;
  input["newPassword"] = std::string(1024, 'x');
  std::string error;
  EXPECT_TRUE(confighttp::validate_password_payload_lengths(input, error)) << error;
}

TEST(ConfigHttpValidatePasswordPayloadLengths, NonObjectBodyRejected) {
  auto input = nlohmann::json::array({1, 2, 3});
  std::string error;
  EXPECT_FALSE(confighttp::validate_password_payload_lengths(input, error));
}
