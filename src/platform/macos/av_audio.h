/**
 * @file src/platform/macos/av_audio.h
 * @brief Declarations for audio capture on macOS.
 */
#pragma once

// platform includes
#import <AVFoundation/AVFoundation.h>

// lib includes
#include "third-party/TPCircularBuffer/TPCircularBuffer.h"

#define kBufferLength 4096

@interface AVAudio: NSObject <AVCaptureAudioDataOutputSampleBufferDelegate> {
@public
  TPCircularBuffer audioSampleBuffer;
}

// Owned by this instance for its whole lifetime (alloc'd in setupMicrophone:,
// released automatically under ARC when this object is deallocated). Under
// the prior MRC code this was `assign` with no matching manual release in
// -dealloc — a pre-existing leak; `strong` is required for correct ARC
// teardown and also closes that leak.
@property (nonatomic, strong) AVCaptureSession *audioCaptureSession;
// Non-owning back-reference: audioConnection is owned by audioOutput (see
// -setupMicrophone:); we only keep it to compare identity in
// -captureOutput:didOutputSampleBuffer:fromConnection:. `unsafe_unretained`
// preserves the exact non-retaining semantics the prior `assign` had under
// MRC (both compile to the same non-owning storage under ARC).
@property (nonatomic, unsafe_unretained) AVCaptureConnection *audioConnection;
// Owned by this instance (alloc'd in setupMicrophone:); was manually
// released in -dealloc under MRC, now released automatically under ARC.
@property (nonatomic, strong) NSCondition *samplesArrivedSignal;

+ (NSArray *)microphoneNames;
+ (AVCaptureDevice *)findMicrophone:(NSString *)name;

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

@end
