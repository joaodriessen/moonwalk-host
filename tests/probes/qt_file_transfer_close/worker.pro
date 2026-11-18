QT += core gui network
CONFIG += c++17 console link_pkgconfig release
CONFIG -= app_bundle
TEMPLATE = app
TARGET = qt-file-transfer-close-worker
PKGCONFIG += openssl sdl2 opus
isEmpty(STARLIGHT_SOURCE): error(Pass STARLIGHT_SOURCE=/path/to/starlight-src)
isEmpty(COMMON_LIBRARY): error(Pass COMMON_LIBRARY=/path/to/libmoonlight-common-c.a)
INCLUDEPATH += $$STARLIGHT_SOURCE/app $$STARLIGHT_SOURCE/moonlight-common-c/moonlight-common-c/src
SOURCES += worker.cc \
 $$STARLIGHT_SOURCE/app/streaming/filetransfer.cpp \
 $$STARLIGHT_SOURCE/app/backend/nvhttp.cpp \
 $$STARLIGHT_SOURCE/app/backend/nvcomputer.cpp \
 $$STARLIGHT_SOURCE/app/backend/nvaddress.cpp \
 $$STARLIGHT_SOURCE/app/backend/nvapp.cpp \
 $$STARLIGHT_SOURCE/app/backend/identitymanager.cpp \
 $$STARLIGHT_SOURCE/app/settings/compatfetcher.cpp
HEADERS += $$STARLIGHT_SOURCE/app/streaming/filetransfer.h $$STARLIGHT_SOURCE/app/backend/nvhttp.h $$STARLIGHT_SOURCE/app/settings/compatfetcher.h
LIBS += $$COMMON_LIBRARY -ldl -pthread
