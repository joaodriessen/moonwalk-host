#include <atomic>
#include <boost/property_tree/json_parser.hpp>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <gtest/gtest.h>
#include <openssl/sha.h>
#include <src/file_transfer.h>
#include <thread>

namespace {
  namespace fs = std::filesystem;

  std::string sha(const std::string &s) {
    unsigned char out[32];
    SHA256((const unsigned char *) s.data(), s.size(), out);
    const char *hex = "0123456789abcdef";
    std::string text;
    for (auto b : out) {
      text += hex[b >> 4];
      text += hex[b & 15];
    }
    return text;
  }

  std::string value(const file_transfer::reply &r, const std::string &key) {
    boost::property_tree::ptree tree;
    std::istringstream in(r.body);
    boost::property_tree::read_json(in, tree);
    return tree.get<std::string>(key);
  }

  struct FileTransfers: testing::Test {
    inline static std::atomic<unsigned> next {0};
    fs::path root = fs::temp_directory_path() / ("skylight-files-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "-" + std::to_string(++next));
    std::unique_ptr<file_transfer::service> service;

    void SetUp() override {
      fs::create_directories(root / "Downloads");
      fs::create_directories(root / "Documents");
      fs::create_directories(root / "Desktop");
      service = std::make_unique<file_transfer::service>(root);
    }

    void TearDown() override {
      service.reset();
      fs::remove_all(root);
    }

    std::string begin(const std::string &bytes, const std::string &name = "note-☃.txt", bool overwrite = false) {
      auto r = service->request("A", {{"op", "beginUpload"}, {"folder", "Downloads"}, {"name", name}, {"size", std::to_string(bytes.size())}, {"sha256", sha(bytes)}, {"overwrite", overwrite ? "1" : "0"}});
      EXPECT_EQ(r.status, 200) << r.body;
      return r.status == 200 ? value(r, "id") : "";
    }

    file_transfer::reply action(const char *op, const std::string &id, const std::string &offset = "0", const std::string &body = {}) {
      return service->request("A", {{"op", op}, {"id", id}, {"offset", offset}}, body);
    }

    std::string read(const fs::path &p) {
      std::ifstream in(p, std::ios::binary);
      return {std::istreambuf_iterator<char>(in), {}};
    }

    unsigned staged() {
      unsigned n = 0;
      for (auto &e : fs::directory_iterator(root / "Downloads")) {
        if (e.path().filename().string().rfind(".skylight-", 0) == 0) {
          ++n;
        }
      }
      return n;
    }
  };
}  // namespace

TEST_F(FileTransfers, BidirectionalChunkedRoundTripHasFinalShaAndNoPartialFinalFile) {
  const std::string bytes(file_transfer::service::max_chunk_bytes + 7, '\x9f');
  auto id = begin(bytes);
  EXPECT_FALSE(fs::exists(root / "Downloads" / "note-☃.txt"));
  ASSERT_EQ(action("chunk", id, "0", bytes.substr(0, file_transfer::service::max_chunk_bytes)).status, 200);
  ASSERT_EQ(action("chunk", id, std::to_string(file_transfer::service::max_chunk_bytes), bytes.substr(file_transfer::service::max_chunk_bytes)).status, 200);
  auto finished = action("finish", id);
  ASSERT_EQ(finished.status, 200) << finished.body;
  EXPECT_EQ(value(finished, "sha256"), sha(bytes));
  EXPECT_EQ(read(root / "Downloads" / "note-☃.txt"), bytes);
  EXPECT_EQ(staged(), 0);
  auto download = service->request("A", {{"op", "beginDownload"}, {"folder", "Downloads"}, {"path", "note-☃.txt"}});
  ASSERT_EQ(download.status, 200);
  id = value(download, "id");
  auto first = action("read", id);
  ASSERT_EQ(first.status, 200);
  auto second = action("read", id, std::to_string(first.body.size()));
  ASSERT_EQ(second.status, 200);
  EXPECT_EQ(first.body + second.body, bytes);
  finished = action("finish", id);
  ASSERT_EQ(finished.status, 200);
  EXPECT_EQ(value(finished, "sha256"), sha(bytes));
}

TEST_F(FileTransfers, EmptyFileAndNoOverwritePublicationRace) {
  auto id = begin("", "empty");
  EXPECT_EQ(action("finish", id).status, 200);
  EXPECT_EQ(fs::file_size(root / "Downloads" / "empty"), 0);
  id = begin("new", "race");
  ASSERT_EQ(action("chunk", id, "0", "new").status, 200);
  {
    std::ofstream out(root / "Downloads" / "race");
    out << "original";
  }
  EXPECT_NE(action("finish", id).status, 200);
  EXPECT_EQ(read(root / "Downloads" / "race"), "original");
  EXPECT_EQ(staged(), 0);
}

TEST_F(FileTransfers, BadDigestOrIncompleteUploadKeepsExistingOriginal) {
  {
    std::ofstream out(root / "Downloads" / "existing");
    out << "original";
  }
  auto id = begin("good", "existing", true);
  ASSERT_EQ(action("chunk", id, "0", "evil").status, 200);
  EXPECT_NE(action("finish", id).status, 200);
  EXPECT_EQ(read(root / "Downloads" / "existing"), "original");
  EXPECT_EQ(staged(), 0);
  id = begin("longer", "existing", true);
  ASSERT_EQ(action("chunk", id, "0", "x").status, 200);
  EXPECT_NE(action("finish", id).status, 200);
  EXPECT_EQ(read(root / "Downloads" / "existing"), "original");
  EXPECT_EQ(staged(), 0);
}

TEST_F(FileTransfers, OwnershipCancelAndTraversalDoNotTouchOtherFiles) {
  auto id = begin("bytes");
  EXPECT_EQ(service->request("B", {{"op", "cancel"}, {"id", id}}).status, 403);
  EXPECT_EQ(staged(), 1);
  EXPECT_EQ(action("cancel", id).status, 200);
  EXPECT_EQ(staged(), 0);
  EXPECT_EQ(action("chunk", id, "0", "bytes").status, 404);
  EXPECT_EQ(service->request("A", {{"op", "list"}, {"folder", "Downloads"}, {"path", "../Documents"}}).status, 400);
  EXPECT_EQ(service->request("A", {{"op", "beginUpload"}, {"folder", "Downloads"}, {"name", "../outside"}, {"size", "0"}, {"sha256", sha("")}}).status, 400);
  EXPECT_FALSE(fs::exists(root / "outside"));
}

TEST_F(FileTransfers, ChangedDownloadAndOutOfOrderChunkAreRejected) {
  {
    std::ofstream out(root / "Documents" / "source");
    out << "abc";
  }
  auto result = service->request("A", {{"op", "beginDownload"}, {"folder", "Documents"}, {"path", "source"}});
  ASSERT_EQ(result.status, 200);
  auto id = value(result, "id");
  EXPECT_EQ(action("read", id).body, "abc");
  {
    std::ofstream out(root / "Documents" / "source", std::ios::app);
    out << "d";
  }
  EXPECT_NE(action("finish", id).status, 200);
  id = begin("abc");
  EXPECT_NE(action("chunk", id, "1", "abc").status, 200);
  EXPECT_EQ(staged(), 0);
}

TEST_F(FileTransfers, IdleExpiryReapsOwnedStagingWithoutAnotherRequest) {
  service = std::make_unique<file_transfer::service>(root, std::chrono::seconds(0));
  auto id = begin("abc");
  ASSERT_EQ(staged(), 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(1100));
  EXPECT_EQ(staged(), 0);
  EXPECT_EQ(action("finish", id).status, 404);
}

TEST_F(FileTransfers, OverwritePreservesDestinationEditedOrCreatedDuringTransfer) {
  {
    std::ofstream out(root / "Downloads" / "existing");
    out << "original";
  }
  auto id = begin("new", "existing", true);
  ASSERT_EQ(action("chunk", id, "0", "new").status, 200);
  {
    std::ofstream out(root / "Downloads" / "existing");
    out << "newer edits";
  }
  EXPECT_NE(action("finish", id).status, 200);
  EXPECT_EQ(read(root / "Downloads" / "existing"), "newer edits");
  id = begin("new", "appeared", true);
  ASSERT_EQ(action("chunk", id, "0", "new").status, 200);
  {
    std::ofstream out(root / "Downloads" / "appeared");
    out << "new file";
  }
  EXPECT_NE(action("finish", id).status, 200);
  EXPECT_EQ(read(root / "Downloads" / "appeared"), "new file");
  EXPECT_EQ(staged(), 0);
}

TEST_F(FileTransfers, SessionGenerationChangeRejectsOldTransactionButOwnedCancelRemainsAvailable) {
  auto result = service->request("A", {{"op", "beginUpload"}, {"folder", "Downloads"}, {"name", "scoped"}, {"size", "0"}, {"sha256", sha("")}}, {}, "session-1");
  ASSERT_EQ(result.status, 200);
  auto id = value(result, "id");
  EXPECT_NE(service->request("A", {{"op", "finish"}, {"id", id}}, {}, "session-2").status, 200);
  EXPECT_FALSE(fs::exists(root / "Downloads" / "scoped"));
  EXPECT_EQ(staged(), 0);
  result = service->request("A", {{"op", "beginUpload"}, {"folder", "Downloads"}, {"name", "scoped"}, {"size", "0"}, {"sha256", sha("")}}, {}, "session-1");
  ASSERT_EQ(result.status, 200);
  EXPECT_EQ(service->request("A", {{"op", "cancel"}, {"id", value(result, "id")}}).status, 200);
  EXPECT_EQ(staged(), 0);
}
