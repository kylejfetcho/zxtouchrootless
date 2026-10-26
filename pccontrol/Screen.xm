#include "Screen.h"
#include "Common.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wattributes"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include "headers/IOSurface/IOSurfaceAccelerator.h"
#include "headers/IOSurface/IOMobileFramebuffer.h"
#import "headers/IOSurface/IOSurface.h"
#include "headers/IOSurface/CoreSurface.h"
#pragma clang diagnostic pop

OBJC_EXTERN void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);
OBJC_EXTERN kern_return_t IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
OBJC_EXTERN kern_return_t IOSurfaceUnLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
OBJC_EXTERN IOSurfaceRef IOSurfaceCreate(CFDictionaryRef dictionary);
OBJC_EXTERN CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef surface);

static CGFloat device_screen_width = 0;
static CGFloat device_screen_height = 0;

@implementation Screen
{
    // device screen size
}


/*
Get the size of the screen and set them.
*/
+ (void)setScreenSize:(CGFloat)x height:(CGFloat) y
{
	device_screen_width = x;
	device_screen_height = y;

	if (device_screen_width == 0 || device_screen_height == 0 || device_screen_width > 10000 || device_screen_height > 10000)
	{
		NSLog(@"com.zjx.springboard: Unable to initialze the screen size. screen width: %f, screen height: %f", device_screen_width, device_screen_height);
	}
	else
	{
		NSLog(@"com.zjx.springboard: successfully initialize the screen size. screen width: %f, screen height: %f", device_screen_width, device_screen_height);
	}
}

+ (int)getScreenOrientation
{
    __block int screenOrientation = -1;

    void (^readOrientation)(void) = ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            screenOrientation = [springboard _frontMostAppOrientation];
            //NSLog(@"com.zjx.springboard: orientation %d", screenOrientation);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
    };

    if ([NSThread isMainThread]) {
        readOrientation();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readOrientation);
    }

    return screenOrientation;
}

+ (CGFloat)getScreenWidth
{
    if (device_screen_width == 0)
    {
        NSLog(@"com.zjx.springboard: Cannot get screen width. Maybe you call [Screen getScreenWidth] before springboard getting the screen size.");
    }
    return device_screen_width;
}

+ (CGFloat)getScreenHeight
{
    if (device_screen_height == 0)
    {
        NSLog(@"com.zjx.springboard: Cannot get screen height. Maybe you call [Screen getScreenHeight] before springboard getting the screen size.");
    }
    return device_screen_height;
}

+ (CGFloat)getScale
{    
    return [[UIScreen mainScreen] scale];
}

+ (CGRect)getBounds
{
    return [UIScreen mainScreen].bounds;
}


OBJC_EXTERN UIImage *_UICreateScreenUIImage(void);
+ (NSString*)screenShot
{
    UIImage *screenImage = _UICreateScreenUIImage();
    // Create path.
    NSString *filePath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];

    // Save image.
    [UIImagePNGRepresentation(screenImage) writeToFile:filePath atomically:NO];
    return filePath;
}

+ (UIImage*)screenShotUIImage // memory leak, need to be fixed
{
    return _UICreateScreenUIImage();
}

static Boolean panelIsLandscapeNative(NSString *machine)
{
    if (![machine hasPrefix:@"iPad"]) {
        return false;
    }
    int major = [[machine substringFromIndex:4] intValue]; // "iPad11,6" -> 11
    return major == 8 || major >= 13;
}

+ (CGImageRef)createScreenShotCGImageRef
{
    Boolean isiPad8orUp = false;

    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize screenSize = [UIScreen mainScreen].bounds.size;

    int height = (int)(screenSize.height * scale);
    int width = (int)(screenSize.width * scale);

    // Does this panel have a landscape-native framebuffer? Only the iPads
    // without a home button do: iPad Pro 2018 (iPad8,x) and everything from
    // iPad13,x on. iPad11,x (mini 5, Air 3, 8th gen) and iPad12,x (9th gen)
    // keep the home button and a portrait framebuffer. The previous regex
    // "^iPad[8-9]|iPad[1-9][0-9]+" matched those too, so on an iPad 8th gen
    // the 1620x2160 frame was rendered into a 2160x1620 surface and only a
    // 1620x1620 square survived.
    isiPad8orUp = panelIsLandscapeNative(getDeviceName());

    if (isiPad8orUp)
    {
        if (width < height)
        {
            int temp = width;
            width = height;
            height = temp;
        }
    }
    else
    {
        if (width > height)
        {
            int temp = width;
            width = height;
            height = temp;
        }
    }

    int bytesPerElement = 4;
    int bytesPerRow = roundUp(bytesPerElement * width, 32);

    NSNumber *IOSurfaceBytesPerElement = [NSNumber numberWithInteger:bytesPerElement]; 
    NSNumber *IOSurfaceBytesPerRow = [NSNumber numberWithInteger:bytesPerRow]; // don't know why but it should be a multiple of 32
    NSNumber *IOSurfaceAllocSize = [NSNumber numberWithInteger:bytesPerRow * height]; 
    NSNumber *nheight = [NSNumber numberWithInteger:height]; 
    NSNumber *nwidth = [NSNumber numberWithInteger:width]; 
    NSNumber *IOSurfacePixelFormat = [NSNumber numberWithInteger:1111970369]; 
    NSNumber *IOSurfaceIsGlobal = [NSNumber numberWithInteger:1]; 

    NSDictionary *properties = [[NSDictionary alloc] initWithObjectsAndKeys:IOSurfaceAllocSize, @"IOSurfaceAllocSize"
                                , IOSurfaceBytesPerElement, @"IOSurfaceBytesPerElement", IOSurfaceBytesPerRow, @"IOSurfaceBytesPerRow", nheight, @"IOSurfaceHeight", 
                                IOSurfaceIsGlobal, @"IOSurfaceIsGlobal", IOSurfacePixelFormat, @"IOSurfacePixelFormat", nwidth, @"IOSurfaceWidth", nil];    

    IOSurfaceRef screenSurface = IOSurfaceCreate((__bridge CFDictionaryRef)(properties));

    properties = nil;

    if (!screenSurface) {
        NSLog(@"com.zjx.springboard: Unable to create IOSurface for screenshot.");
        return NULL;
    }

    kern_return_t lockResult = IOSurfaceLock(screenSurface, 0, NULL);
    if (lockResult != KERN_SUCCESS) {
        NSLog(@"com.zjx.springboard: Unable to lock screenshot IOSurface: %d", lockResult);
        CFRelease(screenSurface);
        return NULL;
    }

    CARenderServerRenderDisplay(0, CFSTR("LCD"), screenSurface, 0, 0);
        
    CGImageRef cgImageRef = nil;
    if (screenSurface) {
        cgImageRef = UICreateCGImageFromIOSurface(screenSurface);
        int targetWidth = CGImageGetWidth(cgImageRef);
        int targetHeight = CGImageGetHeight(cgImageRef);

        if (isiPad8orUp) // rotate 90 degrees counterclockwise
        {
            CGColorSpaceRef colorSpaceInfo = CGImageGetColorSpace(cgImageRef);
            CGContextRef bitmap;

            //if (sourceImage.imageOrientation == UIImageOrientationUp || sourceImage.imageOrientation == UIImageOrientationDown) {
                bitmap = CGBitmapContextCreate(NULL, targetHeight, targetWidth, CGImageGetBitsPerComponent(cgImageRef), CGImageGetBytesPerRow(cgImageRef), colorSpaceInfo, kCGImageAlphaPremultipliedFirst);
            //} else {
                //bitmap = CGBitmapContextCreate(NULL, targetHeight, targetWidth, CGImageGetBitsPerComponent(cgImageRef), CGImageGetBytesPerRow(imageRef), colorSpaceInfo, bitmapInfo);

            //}   

            CGFloat degrees = -90.f;
            CGFloat radians = degrees * (M_PI / 180.f);

            if (bitmap) {
                CGContextTranslateCTM (bitmap, 0.5*targetHeight, 0.5*targetWidth);
                CGContextRotateCTM (bitmap, radians);
                CGContextTranslateCTM (bitmap, -0.5*targetWidth, -0.5*targetHeight);

                CGContextDrawImage(bitmap, CGRectMake(0, 0, targetWidth, targetHeight), cgImageRef);

                CGImageRef rotatedImage = CGBitmapContextCreateImage(bitmap);
                if (rotatedImage) {
                    CGImageRelease(cgImageRef);
                    cgImageRef = rotatedImage;
                }
                CGContextRelease(bitmap);
            }
        }
    }
    IOSurfaceUnlock(screenSurface, 0, NULL);
    CFRelease(screenSurface);
    screenSurface = nil;

    return cgImageRef;
}


+ (NSString*)screenShotAlwaysUp
{
     UIImage *screenImage = _UICreateScreenUIImage();
    int orientation = [self getScreenOrientation];

    UIImageOrientation after = UIImageOrientationUp;
    if (orientation == 4)
    {
        after = UIImageOrientationRight;
    }
    else if (orientation == 3)
    {
        after = UIImageOrientationLeft;
    }
    else if (orientation == 2)
    {
        after = UIImageOrientationDown;
    }

    UIImage *result = [UIImage imageWithCGImage:[screenImage CGImage]
              scale:[screenImage scale]
              orientation: after];

    // Create path.
    NSString *filePath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];

    // Save image.
    [UIImagePNGRepresentation(result) writeToFile:filePath atomically:NO];
    return filePath;
}
@end
