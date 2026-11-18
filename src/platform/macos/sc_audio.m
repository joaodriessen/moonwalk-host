/**
 * @file src/platform/macos/sc_audio.m
 * @brief ScreenCaptureKit-based system audio capture implementation.
 * @details Captures system audio by starting a minimal screen capture stream
 *          with audio enabled. This allows capturing all system audio output.
 */
#import "sc_audio.h"

@interface SCAudioCapture () {
    BOOL _bufferInitialized;
    UInt32 _requestedSampleRate;
    UInt8 _requestedChannels;
}
@end

API_AVAILABLE(macos(12.3))
@implementation SCAudioCapture

+ (BOOL)isAvailable {
    if (@available(macOS 12.3, *)) {
        return YES;
    }
    return NO;
}

+ (NSArray<NSString *> *)availableAudioSources {
    // ScreenCaptureKit captures system audio, so we report that as available
    NSMutableArray *sources = [NSMutableArray array];

    if ([SCAudioCapture isAvailable]) {
        [sources addObject:@"System Audio (ScreenCaptureKit)"];
    }

    return sources;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.isCapturing = NO;

        dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
        self.audioQueue = dispatch_queue_create("dev.lizardbyte.sunshine.scAudioQueue", qos);

        self.samplesArrivedSignal = [[NSCondition alloc] init];
    }
    return self;
}

- (TPCircularBuffer *)getAudioBuffer {
    return &_audioSampleBuffer;
}

- (void)dealloc {
    [self stopCapture];
    // Under ARC, samplesArrivedSignal is a __strong property (see sc_audio.h) and
    // is released automatically once this method returns; [super dealloc] is
    // illegal to call explicitly under ARC and is no longer needed.
}

- (void)loadShareableContent:(void (^)(SCShareableContent *, NSError *))completion {
    [SCShareableContent getShareableContentWithCompletionHandler:completion];
}

- (SCStream *)createStreamForDisplay:(SCDisplay *)display configuration:(SCStreamConfiguration *)configuration {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    return [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
}

- (int)startCaptureWithSampleRate:(UInt32)sampleRate channels:(UInt8)channels {
    if (self.isCapturing) return -1;
    [self stopCapture];  // also releases a partially initialized or failed stream
    if (channels != 2 || sampleRate != 48000) {
        NSLog(@"[SCAudioCapture] Native system audio requires 48 kHz stereo negotiation");
        return -1;
    }
    if (!TPCircularBufferInit(&_audioSampleBuffer, kAudioBufferLength)) return -1;
    _bufferInitialized = YES;
    _requestedSampleRate = sampleRate;
    _requestedChannels = channels;

    dispatch_semaphore_t initSemaphore = dispatch_semaphore_create(0);
    NSObject *initState = [[NSObject alloc] init];
    __block BOOL initSuccess = NO;
    [self loadShareableContent:^(SCShareableContent *content, NSError *error) {
        @synchronized(initState) {
            if (!error && content) {
                self.shareableContent = content;
                initSuccess = YES;
            }
        }
        dispatch_semaphore_signal(initSemaphore);
    }];
    long result = dispatch_semaphore_wait(initSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    BOOL initialized;
    @synchronized(initState) { initialized = initSuccess; }
    if (result != 0 || !initialized || self.shareableContent.displays.count == 0) {
        NSLog(@"[SCAudioCapture] No capture content available; audio may be retried");
        [self stopCapture];
        return -1;
    }

    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = 64;
    config.height = 64;
    config.minimumFrameInterval = CMTimeMake(1, 1);
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.queueDepth = 1;
    config.showsCursor = NO;
    config.capturesAudio = YES;
    config.excludesCurrentProcessAudio = YES;
    config.sampleRate = sampleRate;
    config.channelCount = channels;

    SCStream *startedStream = [self createStreamForDisplay:self.shareableContent.displays.firstObject configuration:config];
    @synchronized(self) { self.stream = startedStream; }
    NSError *error = nil;
    if (!startedStream || ![startedStream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.audioQueue error:&error]) {
        NSLog(@"[SCAudioCapture] Failed to configure audio stream: %@", error.localizedDescription);
        [self stopCapture];
        return -1;
    }

    dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
    NSObject *startState = [[NSObject alloc] init];
    __block BOOL startSuccess = NO;
    [startedStream startCaptureWithCompletionHandler:^(NSError *captureError) {
        @synchronized(self) {
            if (!captureError && self.stream == startedStream) {
                self.isCapturing = YES;
                @synchronized(startState) { startSuccess = YES; }
            } else if (!captureError) {
                // A timed-out start may finish after stopCapture retired it.
                // Stop that exact stream; never revive the retired capture.
                [startedStream stopCaptureWithCompletionHandler:^(NSError *unused) {}];
            }
        }
        dispatch_semaphore_signal(startSemaphore);
    }];
    result = dispatch_semaphore_wait(startSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    BOOL started;
    @synchronized(startState) { started = startSuccess; }
    if (result != 0 || !started || !self.isCapturing) {
        NSLog(@"[SCAudioCapture] Audio start failed or timed out; audio may be retried");
        [self stopCapture];
        return -1;
    }
    return 0;
}

- (void)stopCapture {
    // didStopWithError already marks isCapturing=NO. Cleanup must still run.
    SCStream *retiredStream;
    @synchronized(self) {
        self.isCapturing = NO;
        retiredStream = self.stream;
        self.stream = nil;
    }
    if (retiredStream) {
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [retiredStream stopCaptureWithCompletionHandler:^(NSError *error) {
            dispatch_semaphore_signal(stopped);
        }];
        dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    [self.samplesArrivedSignal signal];
    os_unfair_lock_lock(&_bufferLock);
    if (_bufferInitialized) {
        TPCircularBufferCleanup(&_audioSampleBuffer);
        _bufferInitialized = NO;
    }
    os_unfair_lock_unlock(&_bufferLock);
    self.shareableContent = nil;
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"[SCAudioCapture] Stream stopped with error: %@", error.localizedDescription);
    @synchronized(self) {
        if (stream != self.stream) return;
        self.isCapturing = NO;
    }
    [self.samplesArrivedSignal signal];
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {

    if (type == SCStreamOutputTypeAudio) {
        if (stream != self.stream || !self.isCapturing) return;
        // Get the format description to understand the audio format
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (!formatDesc) {
            return;
        }

        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
        if (!asbd) {
            return;
        }

        // Log format on first sample (for debugging)
        static BOOL formatLogged = NO;
        if (!formatLogged) {
            NSLog(@"[SCAudioCapture] Audio format: %.0f Hz, %d channels, %d bits, format flags: 0x%x, non-interleaved: %d",
                  asbd->mSampleRate, asbd->mChannelsPerFrame, asbd->mBitsPerChannel, asbd->mFormatFlags,
                  (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0);
            formatLogged = YES;
        }

        if (asbd->mChannelsPerFrame != _requestedChannels ||
            asbd->mSampleRate != _requestedSampleRate ||
            !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) || asbd->mBitsPerChannel != 32) {
            NSLog(@"[SCAudioCapture] Captured PCM format differs from negotiated stereo; reopening audio");
            self.isCapturing = NO;
            [self.samplesArrivedSignal signal];
            return;
        }

        BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        BOOL isNonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

        // For non-interleaved audio, we need a larger buffer to hold all channels
        // Calculate the required buffer size
        size_t bufferListSize = sizeof(AudioBufferList);
        if (isNonInterleaved && asbd->mChannelsPerFrame > 1) {
            // Need space for multiple AudioBuffer structs
            bufferListSize = sizeof(AudioBufferList) + (asbd->mChannelsPerFrame - 1) * sizeof(AudioBuffer);
        }

        // Allocate the buffer list
        AudioBufferList *audioBufferList = (AudioBufferList *)malloc(bufferListSize);
        if (!audioBufferList) {
            return;
        }

        CMBlockBufferRef blockBuffer = NULL;

        OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            &bufferListSize,
            audioBufferList,
            bufferListSize,
            NULL,
            NULL,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &blockBuffer
        );

        if (status == noErr && audioBufferList->mNumberBuffers > 0) {
            if (isFloat && asbd->mBitsPerChannel == 32) {
                if (isNonInterleaved && audioBufferList->mNumberBuffers >= 2) {
                    // Non-interleaved stereo: need to interleave L and R channels
                    // Buffer 0 = Left channel (L, L, L, ...)
                    // Buffer 1 = Right channel (R, R, R, ...)
                    // Output should be: (L, R, L, R, L, R, ...)

                    float *leftChannel = (float *)audioBufferList->mBuffers[0].mData;
                    float *rightChannel = (float *)audioBufferList->mBuffers[1].mData;
                    size_t samplesPerChannel = audioBufferList->mBuffers[0].mDataByteSize / sizeof(float);

                    // Allocate interleaved buffer
                    size_t interleavedSize = samplesPerChannel * 2 * sizeof(float);
                    float *interleavedData = (float *)malloc(interleavedSize);

                    if (interleavedData) {
                        if (leftChannel && rightChannel) {
                            for (size_t i = 0; i < samplesPerChannel; i++) {
                                interleavedData[i * 2] = leftChannel[i];      // Left
                                interleavedData[i * 2 + 1] = rightChannel[i]; // Right
                            }
                            // Minimal critical section: the malloc/interleave work above already
                            // happened outside the lock. Gate the actual ring-buffer write on
                            // isCapturing so -stopCapture's TPCircularBufferCleanup (same lock)
                            // can never free the buffer out from under an in-flight produce.
                            os_unfair_lock_lock(&_bufferLock);
                            if (self.isCapturing) {
                                TPCircularBufferProduceBytes(&_audioSampleBuffer, interleavedData, interleavedSize);
                            }
                            os_unfair_lock_unlock(&_bufferLock);
                        }
                        free(interleavedData);
                    }
                } else {
                    // Already interleaved Float32 - write directly
                    AudioBuffer audioBuffer = audioBufferList->mBuffers[0];
                    if (audioBuffer.mData && audioBuffer.mDataByteSize > 0) {
                        os_unfair_lock_lock(&_bufferLock);
                        if (self.isCapturing) {
                            TPCircularBufferProduceBytes(&_audioSampleBuffer, audioBuffer.mData, audioBuffer.mDataByteSize);
                        }
                        os_unfair_lock_unlock(&_bufferLock);
                    }
                }

                // Signal that samples have arrived
                [self.samplesArrivedSignal signal];
            } else {
                // Unsupported format
                static BOOL unknownFormatLogged = NO;
                if (!unknownFormatLogged) {
                    NSLog(@"[SCAudioCapture] Unsupported audio format: %d bits, float: %d, flags: 0x%x",
                          asbd->mBitsPerChannel, isFloat, asbd->mFormatFlags);
                    unknownFormatLogged = YES;
                }
            }
        }

        free(audioBufferList);

        if (blockBuffer) {
            CFRelease(blockBuffer);
        }
    }
    // We ignore video frames (type == SCStreamOutputTypeScreen)
}

@end
