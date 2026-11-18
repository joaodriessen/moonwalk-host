#include <gtest/gtest.h>
#include <src/crypto.h>
#include <src/nvhttp.h>

TEST(AuthenticatedDeviceIdentity, ResolvesActualCertificateNotSameSubjectOrClaimedID) {
  const auto first = crypto::gen_creds("Same client name", 2048);
  const auto other = crypto::gen_creds("Same client name", 2048);
  const auto result = nvhttp::resolve_device_fixture_for_tests(first.x509, first.x509);
  ASSERT_TRUE(result);
  EXPECT_EQ(result->uuid, "paired-device-uuid");
  EXPECT_EQ(result->name, "Same display name");
  EXPECT_FALSE(nvhttp::resolve_device_fixture_for_tests(other.x509, first.x509));
  EXPECT_FALSE(nvhttp::resolve_device_fixture_for_tests("invalid certificate", first.x509));
  EXPECT_FALSE(nvhttp::authenticated_device_for_certificate(nullptr));
}
