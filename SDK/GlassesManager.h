#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface GlassesManager : NSObject

+ (instancetype)sharedManager;

/// デバイスへの接続と初期化（Carinaの場合は自動で3840x1200に解像度変更します）
- (BOOL)setupAndConnect;

/// カメラストリーミングの開始
- (void)startStreamingWithHandler:(void (^)(CVPixelBufferRef leftBuffer, CVPixelBufferRef rightBuffer))handler;

/// 6DoF Pose（位置・姿勢）取得スレッドの開始
/// @param handler x, y, z (位置) と qw, qx, qy, qz (クォータニオン) を返すコールバック (100Hzで呼ばれます)
- (void)startPosePollingWithHandler:(void (^)(float x, float y, float z, float qw, float qx, float qy, float qz))handler;

/// 切断処理（解像度を1920x1200に戻してスレッド停止・クリーンアップ）
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
