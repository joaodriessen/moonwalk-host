#ifdef __APPLE__
#include <gtest/gtest.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/stat.h>

namespace {
std::filesystem::path process_test_dir;
void event(const char *name) { std::ofstream(process_test_dir / "events",std::ios::app) << name << '\n'; }
IOReturn inert_activity(CFStringRef, IOPMUserActiveType, IOPMAssertionID *id) {
  event("wake"); std::ofstream(process_test_dir / "wake") << "ready"; *id=42; return kIOReturnSuccess;
}
int inert_settle(useconds_t duration) {
  if (duration==500000) { event("settle"); std::ofstream(process_test_dir / "settle") << "ready"; }
  return ::usleep(duration);
}
}
// Only the existing activity/settle calls are replaced. The actual production
// spawn/read/waitpid/deadline/ACK/geometry code runs against private inert children.
#define IOPMAssertionDeclareUserActivity inert_activity
#define usleep inert_settle
#include <src/platform/macos/vd_mode_process.h>
#undef usleep
#undef IOPMAssertionDeclareUserActivity

namespace {
class MacVdModeProcess : public testing::Test {
protected:
  std::string child;
  void SetUp() override {
    std::string pattern=(std::filesystem::temp_directory_path()/"skylight-vd-process-XXXXXX").string();
    std::vector<char> writable(pattern.begin(),pattern.end());writable.push_back('\0');
    ASSERT_NE(mkdtemp(writable.data()),nullptr);process_test_dir=writable.data();
    child=(process_test_dir/"child").string();
    std::ofstream(child) << R"SH(#!/bin/sh
cd "$SKYLIGHT_VD_PROCESS_DIR" || exit 9
if [ "$7" = 1 ]; then
 echo $$ > setterpid
 echo setter >> events
 if [ "$SKYLIGHT_VD_PROCESS_CASE" = wake ]; then
  [ -f wake ] && [ -f settle ] || exit 7
 fi
 if [ "$SKYLIGHT_VD_PROCESS_CASE" = budget ]; then sleep 2.6; fi
 if [ "$SKYLIGHT_VD_PROCESS_CASE" = forged ]; then
  echo 'VDG1 147 0 0 1440 900 2880 1800 1'; exit 0
 fi
 echo MODE_APPLIED
 [ "$SKYLIGHT_VD_PROCESS_CASE" != badexit ]; exit $?
fi
if [ "$3" = 0 ]; then
 echo preinspect >> events
 [ "$SKYLIGHT_VD_PROCESS_CASE" != prefail ] || { echo MODE_ERROR; exit 2; }
 if [ "$SKYLIGHT_VD_PROCESS_CASE" = prebudget ]; then sleep 2.6; fi
 if [ "$SKYLIGHT_VD_PROCESS_CASE" = headless ]; then
  echo 'VDG1 147 0 0 2880 1800 2880 1800 1'
 else
  echo 'VDG1 147 1920 0 2880 1800 2880 1800 0'
 fi
 exit 0
fi
# A live or unreaped setter would still respond to kill -0.
kill -0 "$(cat setterpid)" 2>/dev/null && exit 8
echo reader >> events
if [ "$SKYLIGHT_VD_PROCESS_CASE" = budget ]; then sleep .7; fi
if [ "$SKYLIGHT_VD_PROCESS_CASE" = stale ]; then
 echo 'VDG1 147 1920 0 2880 1800 2880 1800 0'
else
 echo 'VDG1 147 0 0 1440 900 2880 1800 1'
fi
)SH";
    ASSERT_EQ(chmod(child.c_str(),0700),0);
    setenv("SKYLIGHT_VD_PROCESS_DIR",process_test_dir.c_str(),1);
  }
  void TearDown() override {
    unsetenv("SKYLIGHT_VD_PROCESS_DIR");unsetenv("SKYLIGHT_VD_PROCESS_CASE");
    std::filesystem::remove_all(process_test_dir);
  }
  void scenario(const char *value) { setenv("SKYLIGHT_VD_PROCESS_CASE",value,1); }
  std::vector<std::string> events() {
    std::ifstream file(process_test_dir/"events");std::vector<std::string> values;std::string line;
    while(std::getline(file,line))values.push_back(line);return values;
  }
};

TEST_F(MacVdModeProcess, SuccessfulSetterIsReapedBeforeSeparateFreshReader) {
  scenario("valid");vd_geometry_t g{};
  ASSERT_TRUE(freshMode(child.c_str(),147,2880,1800,60,2,YES,&g));
  EXPECT_EQ(g.logical_width,1440);EXPECT_EQ(g.pixel_width,2880);
  EXPECT_EQ(events(),(std::vector<std::string>{"setter","reader"}));
}

TEST_F(MacVdModeProcess, InvalidMutationAckAndStaleGeometryFailClosed) {
  for(const char *name:{"forged","badexit","stale"}) {
    scenario(name);vd_geometry_t g{};
    EXPECT_FALSE(freshMode(child.c_str(),147,2880,1800,60,2,YES,&g)) << name;
  }
}

TEST_F(MacVdModeProcess, SelectorAndObserverShareDeadline) {
  scenario("budget");vd_geometry_t g{};double start=monotonicSeconds();
  EXPECT_FALSE(freshMode(child.c_str(),147,2880,1800,60,2,YES,&g));
  EXPECT_GE(monotonicSeconds()-start,2.8);EXPECT_LT(monotonicSeconds()-start,4.3);
}

TEST_F(MacVdModeProcess, WakeAndSettlePrecedeModeWithOnePhaseBudget) {
  scenario("wake");vd_geometry_t g{};IOPMAssertionID wake=kIOPMNullAssertionID;BOOL attempted=NO;
  ASSERT_TRUE(prepareDesktopMode(child.c_str(),147,2880,1800,60,2,&g,&wake,&attempted));
  EXPECT_TRUE(attempted);
  EXPECT_EQ(wake,42u); // Assertion belongs to the caller through flip/cleanup.
  EXPECT_EQ(events(),(std::vector<std::string>{"preinspect","wake","settle","setter","reader"}));
}

TEST_F(MacVdModeProcess, AlreadyMainSkipsWakeAndSettle) {
  scenario("headless");vd_geometry_t g{};IOPMAssertionID wake=kIOPMNullAssertionID;BOOL attempted=NO;
  ASSERT_TRUE(prepareDesktopMode(child.c_str(),147,2880,1800,60,2,&g,&wake,&attempted));
  EXPECT_FALSE(attempted);
  EXPECT_EQ(wake,kIOPMNullAssertionID);
  EXPECT_EQ(events(),(std::vector<std::string>{"preinspect","setter","reader"}));
}

TEST_F(MacVdModeProcess, LaterSecondaryStatePreservesWakeBeforeFlipWithoutDuplication) {
  scenario("headless");vd_geometry_t g{};IOPMAssertionID wake=kIOPMNullAssertionID;BOOL attempted=NO;
  ASSERT_TRUE(prepareDesktopMode(child.c_str(),147,2880,1800,60,2,&g,&wake,&attempted));
  // An initially-main VD can become secondary before the actual flip decision.
  ensureConfigurationWake(NO,&attempted,&wake);
  ensureConfigurationWake(NO,&attempted,&wake);
  EXPECT_TRUE(attempted);EXPECT_EQ(wake,42u);
  EXPECT_EQ(events(),(std::vector<std::string>{"preinspect","setter","reader","wake","settle"}));
}

TEST_F(MacVdModeProcess, FailedOrSlowPreinspectionCannotWakeOrMutate) {
  for(const char *name:{"prefail","prebudget"}) {
    scenario(name);vd_geometry_t g{};IOPMAssertionID wake=kIOPMNullAssertionID;BOOL attempted=NO;
    EXPECT_FALSE(prepareDesktopMode(child.c_str(),147,2880,1800,60,2,&g,&wake,&attempted)) << name;
    EXPECT_EQ(wake,kIOPMNullAssertionID);
  }
  EXPECT_EQ(events(),(std::vector<std::string>{"preinspect","preinspect"}));
}
}
#endif
