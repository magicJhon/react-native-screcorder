#import "RCTBridge.h"
#import "RNRecorder.h"
#import "RNRecorderManager.h"
#import "RCTLog.h"
#import "RCTUtils.h"

#import <AVFoundation/AVFoundation.h>

@interface RNRecorder()
@property (nonatomic) AVAssetWriter *assetWrite;
@end

@implementation RNRecorder
{
   /* Required to publish events */
   RCTEventDispatcher *_eventDispatcher;
   /* SCRecorder instance */
   SCRecorder *_recorder;
   /* SCRecorder session instance */
   SCRecordSession *_session;
   /* Preview view ¨*/
   UIView *_previewView;
   /* Configuration */
   NSDictionary *_config;
   /* Camera type (front || back) */
   NSString *_device;

   /* Video format */
   NSString *_videoFormat;
   /* Video quality */
   NSString *_videoQuality;
   /* Video filters */
   NSArray *_videoFilters;

   /* Audio quality */
   NSString *_audioQuality;
   
   /* Realtime Preview */
   BOOL _realtimePreview;
   
   SCFilter *_mirrorFilter;
}

#pragma mark - Init

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
   self = [super initWithFrame:CGRectZero];
   if (self) {
      self.palindromicSaveMode = NO;
      if (_recorder == nil) {
         _recorder = [SCRecorder recorder];
         _recorder.captureSessionPreset = [SCRecorderTools bestCaptureSessionPresetCompatibleWithAllDevices];
         _recorder.delegate = self;
         _recorder.initializeSessionLazily = NO;
      }
   }
   return self;
}

#pragma mark - Setter

- (void)setConfig:(NSDictionary *)config
{
   _config = config;
   NSDictionary *video  = [RCTConvert NSDictionary:[config objectForKey:@"video"]];
   NSDictionary *audio  = [RCTConvert NSDictionary:[config objectForKey:@"audio"]];

   // Recorder config
   _recorder.autoSetVideoOrientation = [RCTConvert BOOL:[config objectForKey:@"autoSetVideoOrientation"]];
   _recorder.flashMode = [RCTConvert int:[config objectForKey:@"flashMode"]];

   // Video config
   _recorder.videoConfiguration.enabled = [RCTConvert BOOL:[video objectForKey:@"enabled"]];
   _recorder.videoConfiguration.bitrate = [RCTConvert int:[video objectForKey:@"bitrate"]];
   _recorder.videoConfiguration.timeScale = [RCTConvert float:[video objectForKey:@"timescale"]];
   _videoFormat = [RCTConvert NSString:[video objectForKey:@"format"]];
   [self setVideoFormat:_videoFormat];
   _videoQuality = [RCTConvert NSString:[video objectForKey:@"quality"]];
   _videoFilters = [RCTConvert NSArray:[video objectForKey:@"filters"]];
   if (_recorder.CIImageRenderer) {
      ((SCImageView *)_recorder.CIImageRenderer).filter = [self createFilter];
      [self mirrorPreviewOnDeviceFront];
   }

   // Audio config
   _recorder.audioConfiguration.enabled = [RCTConvert BOOL:[audio objectForKey:@"enabled"]];
   _recorder.audioConfiguration.bitrate = [RCTConvert int:[audio objectForKey:@"bitrate"]];
   _recorder.audioConfiguration.channelsCount = [RCTConvert int:[audio objectForKey:@"channelsCount"]];
   _audioQuality = [RCTConvert NSString:[audio objectForKey:@"quality"]];

   // Audio format
   NSString *format = [RCTConvert NSString:[audio objectForKey:@"format"]];
   if ([format isEqual:@"MPEG4AAC"]) {
      _recorder.audioConfiguration.format = kAudioFormatMPEG4AAC;
   }
}

- (void)setDevice:(NSString*)device
{
   _device = device;
   if ([device  isEqual: @"front"]) {
      _recorder.device = AVCaptureDevicePositionFront;
   } else if ([device  isEqual: @"back"]) {
      _recorder.device = AVCaptureDevicePositionBack;
   }
   [self mirrorPreviewOnDeviceFront];
}

- (void)setVideoFormat:(NSString*)format
{
   _videoFormat = format;
   if ([_videoFormat  isEqual: @"MPEG4"]) {
      _videoFormat = AVFileTypeMPEG4;
   } else if ([_videoFormat  isEqual: @"MOV"]) {
      _videoFormat = AVFileTypeQuickTimeMovie;
   }
   if (_session != nil) {
      _session.fileType = _videoFormat;
   }
}

- (void)setRealtimePreview:(BOOL)realtimePreview {
   if (_realtimePreview != realtimePreview) {
      _realtimePreview = realtimePreview;
      if (_previewView) {
         [_previewView removeFromSuperview];
         _previewView = _realtimePreview ? (UIView *)_recorder.CIImageRenderer : _recorder.previewView;
         [self insertSubview:_previewView atIndex:0];
      }
   }
}

#pragma mark - Private Methods

- (void)mirrorPreviewOnDeviceFront {
   if ([_device  isEqual: @"front"]) {
      [self mirrorPreview:YES];
   } else if ([_device isEqual: @"back"]) {
      [self mirrorPreview:NO];
   }
}

- (void)mirrorPreview:(BOOL)needMirror {
   SCFilter *filter = ((SCImageView *)_recorder.CIImageRenderer).filter;
   if (filter) {
      if (needMirror) {
         CGAffineTransform mirrorTransform = CGAffineTransformMakeScale(-1, 1);
         _mirrorFilter = [SCFilter filterWithAffineTransform:mirrorTransform];
         [filter addSubFilter:_mirrorFilter];
      } else {
         [filter removeSubFilter:_mirrorFilter];
         _mirrorFilter = nil;
      }
   }
}

- (NSArray *)sortFilterKeys:(NSDictionary *)dictionary {

   NSArray *keys = [dictionary allKeys];
   NSArray *sortedKeys = [keys sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
      NSString *key1 = (NSString*)obj1;

      if ([key1 isEqualToString:@"CIfilter"] || [key1 isEqualToString:@"file"])
         return (NSComparisonResult)NSOrderedAscending;
      else
         return (NSComparisonResult)NSOrderedDescending;
   }];

   return sortedKeys;
}

- (SCFilter*)createFilter
{
   SCFilter *filter = [SCFilter emptyFilter];

   for (NSDictionary* subfilter in _videoFilters) {
      SCFilter *subscfilter = [SCFilter emptyFilter];
      NSArray *sortedKeys = [self sortFilterKeys:subfilter];

      for (NSString* propkey in sortedKeys) {

         // CIfilter specified
         if ([propkey isEqualToString:@"CIfilter"]) {
            NSString *name = [RCTConvert NSString:[subfilter objectForKey:propkey]];
            subscfilter = [SCFilter filterWithCIFilterName:name];
            if (subscfilter == nil) {
               RCTLogError(@"CIfilter %@ not found", name);
               subscfilter = [SCFilter emptyFilter];
            }
         }
         // Filter file specified
         else if ([propkey isEqualToString:@"file"]) {
            NSString *path = [RCTConvert NSString:[subfilter objectForKey:propkey]];
            subscfilter = [SCFilter filterWithContentsOfURL:[[NSBundle mainBundle] URLForResource:path withExtension:@"cisf"]];
            if (subscfilter == nil) {
               RCTLogError(@"CSIF file %@ not found", path);
               subscfilter = [SCFilter emptyFilter];
            }
         }
         // Animations specified
         else if ([propkey isEqualToString:@"animations"]) {
            NSArray *animations = [RCTConvert NSArray:[subfilter objectForKey:propkey]];

            for (NSDictionary* anim in animations) {
               NSString *name = [RCTConvert NSString:[anim objectForKey:@"name"]];
               NSNumber *startValue = [RCTConvert NSNumber:[anim objectForKey:@"startValue"]];
               NSNumber *endValue = [RCTConvert NSNumber:[anim objectForKey:@"endValue"]];
               double   startTime = [RCTConvert double:[anim objectForKey:@"startTime"]];
               double   duration = [RCTConvert double:[anim objectForKey:@"duration"]];

               [subscfilter addAnimationForParameterKey:name startValue:startValue endValue:endValue startTime:startTime duration:duration];
            }
         }
         else {
            NSNumber *val = [RCTConvert NSNumber:[subfilter objectForKey:propkey]];
            [subscfilter setParameterValue:val forKey:propkey];
         }
      }
      [filter addSubFilter:subscfilter];
   }
   return filter;
}

- (NSString*)saveImage:(UIImage*)image
{
   NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
   NSString *name = [[NSProcessInfo processInfo] globallyUniqueString];
   name = [name stringByAppendingString:@".png"];
   NSString *filePath = [[paths objectAtIndex:0] stringByAppendingPathComponent:name];

   UIImage *resImage = image;
   if ([_device isEqualToString:@"front"]) {
      resImage = [UIImage imageWithCGImage:image.CGImage scale:image.scale orientation:(image.imageOrientation + 4) % 8];
   }

   [UIImageJPEGRepresentation(resImage, 1.0) writeToFile:filePath atomically:YES];
   
   return filePath;
}

- (void)segmentByReversingAsset:(AVAsset *)asset completionHandler:(void (^)(AVAsset *))handler {
   NSError *error;
   AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
   AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] lastObject];
   
   NSDictionary *readerOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange], kCVPixelBufferPixelFormatTypeKey, nil];
   AVAssetReaderTrackOutput *readerOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                                                       outputSettings:readerOutputSettings];
   
   [reader addOutput:readerOutput];
   [reader startReading];
   
   // read in the samples
   NSMutableArray *samples = [[NSMutableArray alloc] init];
   
   CMSampleBufferRef sample;
   while((sample = [readerOutput copyNextSampleBuffer])) {
      [samples addObject:(__bridge id)sample];
      CFRelease(sample);
   }
   
   NSString *name = [NSString stringWithFormat:@"%@.%@", [[NSProcessInfo processInfo] globallyUniqueString], @"mp4"];
   NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
   
   self.assetWrite = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeMPEG4 error:&error];
   NSDictionary *videoCompressProps = @{AVVideoAverageBitRateKey: @(videoTrack.estimatedDataRate)};
   NSDictionary *writerOutputSettings = @{AVVideoCodecKey: AVVideoCodecH264,
                                          AVVideoWidthKey: @(videoTrack.naturalSize.width),
                                          AVVideoHeightKey: @(videoTrack.naturalSize.height),
                                          AVVideoCompressionPropertiesKey: videoCompressProps};
   AVAssetWriterInput *writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                                    outputSettings:writerOutputSettings
                                                                  sourceFormatHint:(__bridge CMFormatDescriptionRef)videoTrack.formatDescriptions.lastObject];
   [writerInput setExpectsMediaDataInRealTime:NO];
   
   // Initialize an input adaptor so that we can append PixelBuffer
   AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor =
      [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:writerInput
                                                 sourcePixelBufferAttributes:nil];
   [self.assetWrite addInput:writerInput];
   [self.assetWrite startWriting];
   [self.assetWrite startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)samples[0])];
   
   // Append the frames to the output.
   // Notice we append the frames from the tail end, using the timing of the frames from the front.
   for(NSInteger i = 0; i < samples.count; i++) {
      // Get the presentation time for the frame
      CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)samples[i]);
      
      // take the image/pixel buffer from tail end of the array
      CVPixelBufferRef imageBufferRef = CMSampleBufferGetImageBuffer((__bridge CMSampleBufferRef)samples[samples.count - i - 1]);
      
      while (!writerInput.readyForMoreMediaData) {
         [NSThread sleepForTimeInterval:0.1];
      }
      
      [pixelBufferAdaptor appendPixelBuffer:imageBufferRef withPresentationTime:presentationTime];
      
   }
   
   [self.assetWrite finishWritingWithCompletionHandler:^{
      handler([AVAsset assetWithURL:outputURL]);
      self.assetWrite = nil;
   }];
}

- (void)commonSaveAsset:(AVAsset *)asset callback:(void(^)(NSError *error, NSURL *outputUrl))callback {
   SCAssetExportSession *assetExportSession = [[SCAssetExportSession alloc] initWithAsset:asset];
   assetExportSession.outputFileType = _videoFormat;
   assetExportSession.outputUrl = [_session outputUrl];
   assetExportSession.videoConfiguration.preset = _videoQuality;
   assetExportSession.audioConfiguration.preset = _audioQuality;
   
   // Apply filters
   SCFilter *filter = [self createFilter];
//   if ([_device isEqual: @"front"]) {
//      CGAffineTransform mirrorTransform = CGAffineTransformMakeScale(-1.0, 1);
//      [filter addSubFilter:[SCFilter filterWithAffineTransform:mirrorTransform]];
//   }
   assetExportSession.videoConfiguration.filter = filter;
   
   
   [assetExportSession exportAsynchronouslyWithCompletionHandler: ^{
      callback(assetExportSession.error, assetExportSession.outputUrl);
   }];
}

- (AVAsset *)mergeAsset:(AVAsset *)asset another:(AVAsset *)another trimRatio:(CGFloat)trimRatio {
   AVMutableComposition *composition = [[AVMutableComposition alloc] init];
   AVMutableCompositionTrack *mutableCompVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                          preferredTrackID:kCMPersistentTrackID_Invalid];
   AVMutableCompositionTrack *mutableCompAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                          preferredTrackID:kCMPersistentTrackID_Invalid];
   
   CMTime currentCTime = kCMTimeZero;
   CMTime start = CMTimeMake(asset.duration.value * trimRatio, asset.duration.timescale);
   CMTime duration = CMTimeMake(asset.duration.value * (1 - trimRatio), asset.duration.timescale);
   CMTimeRange timeRange = CMTimeRangeMake(start, duration);
   if ([[asset tracksWithMediaType:AVMediaTypeAudio] count]) {
      [mutableCompAudioTrack insertTimeRange:timeRange
                                     ofTrack:[[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0]
                                      atTime:currentCTime error:nil];
   }
   if ([[asset tracksWithMediaType:AVMediaTypeVideo] count]) {
      [mutableCompVideoTrack insertTimeRange:timeRange
                                     ofTrack:[[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0]
                                      atTime:currentCTime
                                       error:nil];
   }
   
   currentCTime = CMTimeAdd(currentCTime, duration);
   start = kCMTimeZero;
   duration = CMTimeMake(another.duration.value * (1 - trimRatio), another.duration.timescale);
   timeRange = CMTimeRangeMake(start, duration);
   if ([[another tracksWithMediaType:AVMediaTypeAudio] count]) {
      [mutableCompAudioTrack insertTimeRange:timeRange
                                     ofTrack:[[another tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0]
                                      atTime:currentCTime
                                       error:nil];
   }
   if ([[another tracksWithMediaType:AVMediaTypeVideo] count]) {
      [mutableCompVideoTrack insertTimeRange:timeRange
                                     ofTrack:[[another tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0]
                                      atTime:currentCTime
                                       error:nil];
   }
   
   if (self.palindromicSaveMode) {
      [composition removeTrack:mutableCompAudioTrack];
   }
   
   return composition;
}

#pragma mark - Public Methods

- (void)record
{
   [_recorder record];
}

- (void)capture:(void(^)(NSError *error, NSString *url))callback
{
   [_recorder capturePhoto:^(NSError *error, UIImage *image) {
      NSString *imgPath = [self saveImage:image];
      callback(error, imgPath);
   }];
}

- (void)pause:(void(^)())completionHandler
{
   [_recorder pause:completionHandler];
}

- (SCRecordSessionSegment*)lastSegment
{
   return [_session.segments lastObject];
}

- (void)removeLastSegment
{
   [_session removeLastSegment];
}

- (void)removeAllSegments
{
   [_session removeAllSegments:true];
}

- (void)removeSegmentAtIndex:(NSInteger)index
{
   [_session removeSegmentAtIndex:index deleteFile:true];
}

- (void)save:(void(^)(NSError *error, NSURL *outputUrl))callback
{
   AVAsset *asset = _session.assetRepresentingSegments;
   if (self.palindromicSaveMode) {
      [self segmentByReversingAsset:asset completionHandler:^(AVAsset *reversedAsset) {
         [self commonSaveAsset:[self mergeAsset:asset
                                        another:reversedAsset
                                      trimRatio:self.discardRatio.floatValue] 
                      callback:callback];
      }];
   } else {
      [self commonSaveAsset:[_session assetRepresentingSegments] callback:callback];
   }
}


#pragma mark - SCRecorder events

- (void)recorder:(SCRecorder *)recorder didInitializeAudioInSession:(SCRecordSession *)recordSession error:(NSError *)error {
   if (error == nil) {
      NSLog(@"Initialized audio in record session");
   } else {
      NSLog(@"Failed to initialize audio in record session: %@", error.localizedDescription);
   }
}

- (void)recorder:(SCRecorder *)recorder didInitializeVideoInSession:(SCRecordSession *)recordSession error:(NSError *)error {
   if (error == nil) {
      NSLog(@"Initialized video in record session");
   } else {
      NSLog(@"Failed to initialize video in record session: %@", error.localizedDescription);
   }
}

#pragma mark - React View Management


- (void)layoutSubviews
{
   [super layoutSubviews];

   if (_previewView == nil) {
      SCImageView *ciImageRenderer = [[SCImageView alloc] initWithFrame:self.bounds];
      ciImageRenderer.CIImage = [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]];
      ciImageRenderer.filter = [self createFilter];
      _recorder.CIImageRenderer = ciImageRenderer;
      [self mirrorPreviewOnDeviceFront];
      
      UIView *view = [[UIView alloc] initWithFrame:self.bounds];
      [view setBackgroundColor:[UIColor blackColor]];
      _recorder.previewView = view;
      
      _previewView = _realtimePreview ? (UIView *)_recorder.CIImageRenderer : _recorder.previewView;
      [self insertSubview:_previewView atIndex:0];
      
      // [_recorder startRunning];
      //
      // _session = [SCRecordSession recordSession];
      // [self setVideoFormat:_videoFormat];
      // _recorder.session = _session;
   }

   return;
}

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
   [self addSubview:view];
}

- (void)removeReactSubview:(UIView *)subview
{
   [subview removeFromSuperview];
}

- (void)removeFromSuperview
{
   [super removeFromSuperview];
}

- (void)orientationChanged:(NSNotification *)notification
{
   [_recorder previewViewFrameChanged];
}

- (BOOL)startRunning {
   BOOL res = [_recorder startRunning];
   _session = [SCRecordSession recordSession];
   [self setVideoFormat:_videoFormat];
   _recorder.session = _session;
   [_recorder focusCenter];
   return res;
}

- (void)stopRunning {
   [_recorder stopRunning];
   [_recorder unprepare];
}

@end
