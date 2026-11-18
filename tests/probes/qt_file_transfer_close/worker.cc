// Local integration probe: links the actual Starlight FileTransfer/NvHTTP sources.
// It uses only a temporary identity/files and a caller-provided loopback TLS fixture.
#include "backend/identitymanager.h"
#include "backend/nvcomputer.h"
#include "streaming/filetransfer.h"

#include <cstdio>
#include <QCoreApplication>
#include <QDebug>
#include <QEventLoop>
#include <QFile>
#include <QSettings>
#include <QTemporaryDir>
#include <QTimer>

int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  qInstallMessageHandler([](QtMsgType, const QMessageLogContext &, const QString &s) {
    fprintf(stderr, "%s\n", s.toUtf8().constData());
  });
  QTemporaryDir temp;
  app.setOrganizationName("PrivateTransportFixture");
  app.setApplicationName("LocalWorker");
  QSettings::setPath(QSettings::NativeFormat, QSettings::UserScope, temp.path());
  IdentityManager::get()->getSslConfig();
  QFile pub(QString(argv[1]) + ".client.pem");
  pub.open(QIODevice::WriteOnly);
  pub.write(IdentityManager::get()->getCertificate());
  pub.close();
  QFile cert(argv[1]);
  cert.open(QIODevice::ReadOnly);
  auto host = QSharedPointer<NvComputer>::create();
  host->setOwner(host);
  host->activeAddress = NvAddress("127.0.0.1", QString(argv[2]).toInt());
  host->activeHttpsPort = QString(argv[2]).toInt();
  host->serverCert = QSslCertificate(cert.readAll());
  host->isNvidiaServerSoftware = false;
  QByteArray expected(2 * 1024 * 1024 + 37, Qt::Uninitialized);
  for (qsizetype n = 0; n < expected.size(); ++n) {
    expected[n] = char((n * 17 + n / 257) % 256);
  }
  QFile source(temp.filePath("source.bin"));
  source.open(QIODevice::WriteOnly);
  source.write(expected);
  source.close();
  FileTransfer transfer(host.data(), true);
  auto run = [&](bool upload) {
    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);
    QObject::connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit);
    auto c = QObject::connect(&transfer, &FileTransfer::changed, &loop, [&] {
      qInfo() << "worker" << transfer.busy() << transfer.progress() << transfer.total() << transfer.error();
      if (!transfer.busy()) {
        loop.quit();
      }
    });
    timer.start(10000);
    if (upload) {
      transfer.sendFile(QUrl::fromLocalFile(source.fileName()), "Downloads", "owned-fixture", QString::fromUtf8("worker-☃-café.bin"));
    } else {
      transfer.receiveFile("Downloads", QString::fromUtf8("owned-fixture/worker-☃-café.bin"), QUrl::fromLocalFile(temp.filePath("received.bin")));
    }
    if (transfer.busy()) {
      loop.exec();
    }
    QObject::disconnect(c);
    if (transfer.busy() || !transfer.error().isEmpty()) {
      return false;
    }
    return true;
  };
  if (argc > 3) {
    if (run(true) || transfer.error() != QStringLiteral("fixture HTTP ") + QString(argv[3])) {
      return 5;
    }
    fprintf(stderr, "PASS completed HTTP error %s preserved\n", argv[3]);
  }
  if (!run(true)) {
    return 2;
  }
  if (!run(false)) {
    return 3;
  }
  QFile result(temp.filePath("received.bin"));
  if (!result.open(QIODevice::ReadOnly) || result.readAll() != expected) {
    return 4;
  }
  fprintf(stderr, "PASS actual FileTransfer upload/download %lld bytes\n", (long long) expected.size());
  return 0;
}
