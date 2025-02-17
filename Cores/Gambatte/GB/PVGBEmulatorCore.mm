/*
 Copyright (c) 2015, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "PVGBEmulatorCore.h"
#import <PVSupport/OERingBuffer.h>

#if !TARGET_OS_MACCATALYST
#import <OpenGLES/gltypes.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/EAGL.h>
#else
#import <OpenGL/OpenGL.h>
#import <GLUT/GLUT.h>
#endif

#import <PVGB/PVGB-Swift.h>

#include "gambatte.h"
#include "gbcpalettes.h"
#include "resamplerinfo.h"
#include "resampler.h"

gambatte::GB gb;
Resampler *resampler;
uint32_t gb_pad[PVGBButtonCount];

@interface PVGBEmulatorCore ()
{
    uint32_t *videoBuffer;
    uint32_t *inSoundBuffer;
    int16_t *outSoundBuffer;
    double sampleRate;
    GBPalette displayMode;
}
- (void)outputAudio:(unsigned)frames;
- (void)applyCheat:(NSString *)code;
- (void)loadPalette;
@end

@implementation PVGBEmulatorCore

static __weak PVGBEmulatorCore *_current;

class GetInput : public gambatte::InputGetter
{
public:
    unsigned operator()()
    {
        __strong PVGBEmulatorCore *strongCurrent = _current;
        if (strongCurrent.controller1)
        {
            [strongCurrent updateControllers];
        }

        return gb_pad[0];
    }
} static GetInput;

- (id)init
{
    if((self = [super init]))
    {
        videoBuffer = (uint32_t *)malloc(160 * 144 * 4);
        inSoundBuffer = (uint32_t *)malloc(2064 * 2 * 4);
        outSoundBuffer = (int16_t *)malloc(2064 * 2 * 2);
        displayMode = GBPalettePeaSoupGreen;
    }

	_current = self;

	return self;
}

- (void)dealloc
{
    free(videoBuffer);
    free(inSoundBuffer);
    free(outSoundBuffer);
}

# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError**)error
{
    memset(gb_pad, 0, sizeof(uint32_t) * PVGBButtonCount);

    // Set battery save dir
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:[self batterySavesPath]];
    [[NSFileManager defaultManager] createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    gb.setSaveDir([[batterySavesDirectory path] UTF8String]);

    // Set input state callback
    gb.setInputGetter(&GetInput);

    // Setup resampler
    double fps = 4194304.0 / 70224.0;
    double inSampleRate = fps * 35112; // 2097152

    // 2 = "Very high quality (polyphase FIR)", see resamplerinfo.cpp
    resampler = ResamplerInfo::get(2).create(inSampleRate, 48000.0, 2 * 2064);

    unsigned long mul, div;
    resampler->exactRatio(mul, div);

    double outSampleRate = inSampleRate * mul / div;
    sampleRate = outSampleRate; // 47994.326636

    if (gb.load([path UTF8String]) != 0) {
        if (error) {
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: @"Failed to load game.",
                                       NSLocalizedFailureReasonErrorKey: @"Gambatte failed to load ROM.",
                                       NSLocalizedRecoverySuggestionErrorKey: @"Check that file isn't corrupt and in format Gambatte supports."
                                       };

            NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                                    code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                                userInfo:userInfo];

            *error = newError;
        }
        return NO;
    }

    // Load built-in GBC palette for monochrome games if supported
	if (gb.isCgb()) {
		[self setPalette];
	} else {
		[self loadPalette];
	}
    return YES;
}

-(BOOL)isGameboyColor {
	return gb.isCgb();
}

- (void)executeFrame
{
    [self executeFrameSkippingFrame:NO];
}

- (void)executeFrameSkippingFrame:(BOOL)skip
{
    size_t samples = 2064;

    while (gb.runFor(videoBuffer, 160, inSoundBuffer, samples) == -1)
    {
        [self outputAudio:samples];
    }

    [self outputAudio:samples];
}

- (void)resetEmulation
{
    gb.reset();
}

- (void)stopEmulation
{
    if (self.isRunning)
    {
        gb.saveSavedata();

        delete resampler;

        [super stopEmulation];
    }
}

- (NSTimeInterval)frameInterval
{
    return 59.727501;
}

# pragma mark - Video

- (const void *)videoBuffer
{
    return videoBuffer;
}

- (CGRect)screenRect
{
    return CGRectMake(0, 0, 160, 144);
}

- (CGSize)bufferSize
{
    return CGSizeMake(160, 144);
}

- (CGSize)aspectSize
{
    return CGSizeMake(10, 9);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_BYTE;
}

- (GLenum)internalPixelFormat
{
    return GL_RGBA;
}

# pragma mark - Audio


- (double)audioSampleRate
{
    return sampleRate;
}

- (NSUInteger)channelCount
{
    return 2;
}

# pragma mark - Save States

- (BOOL)saveStateToFileAtPath:(NSString *)fileName error:(NSError**)error  
{
    @synchronized(self) {
        BOOL success = gb.saveState(0, 0, [fileName UTF8String]);
		if (!success) {
            if (error) {
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: @"Failed to save state.",
                                           NSLocalizedFailureReasonErrorKey: @"Core failed to create save state.",
                                           NSLocalizedRecoverySuggestionErrorKey: @""
                                           };

                NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                                        code:PVEmulatorCoreErrorCodeCouldNotSaveState
                                                    userInfo:userInfo];

                *error = newError;
            }
		}
		return success;
    }
}

- (BOOL)loadStateFromFileAtPath:(NSString *)fileName error:(NSError**)error
{
    @synchronized(self) {
        BOOL success = gb.loadState([fileName UTF8String]);
		if (!success) {
            if (error) {
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: @"Failed to load state.",
                                           NSLocalizedFailureReasonErrorKey: @"Core failed to load save state.",
                                           NSLocalizedRecoverySuggestionErrorKey: @""
                                           };

                NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
                                                        code:PVEmulatorCoreErrorCodeCouldNotLoadState
                                                    userInfo:userInfo];

                *error = newError;
            }
		}
		return success;
    }
}

# pragma mark - Input

const int GBMap[] = {gambatte::InputGetter::UP, gambatte::InputGetter::DOWN, gambatte::InputGetter::LEFT, gambatte::InputGetter::RIGHT, gambatte::InputGetter::A, gambatte::InputGetter::B, gambatte::InputGetter::START, gambatte::InputGetter::SELECT};
- (void)didPushGBButton:(PVGBButton)button forPlayer:(NSInteger)player
{
    gb_pad[0] |= GBMap[button];
}

- (void)didReleaseGBButton:(PVGBButton)button forPlayer:(NSInteger)player
{
    gb_pad[0] &= ~GBMap[button];
}

- (void)updateControllers
{
    if ([self.controller1 extendedGamepad])
    {
        GCExtendedGamepad *gamepad = [self.controller1 extendedGamepad];
        GCControllerDirectionPad *dpad = [gamepad dpad];

        (dpad.up.isPressed || gamepad.leftThumbstick.up.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonUp] : gb_pad[0] &= ~GBMap[PVGBButtonUp];
        (dpad.down.isPressed || gamepad.leftThumbstick.down.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonDown] : gb_pad[0] &= ~GBMap[PVGBButtonDown];
        (dpad.left.isPressed || gamepad.leftThumbstick.left.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonLeft] : gb_pad[0] &= ~GBMap[PVGBButtonLeft];
        (dpad.right.isPressed || gamepad.leftThumbstick.right.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonRight] : gb_pad[0] &= ~GBMap[PVGBButtonRight];

        (gamepad.buttonA.isPressed || gamepad.buttonY.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonB] : gb_pad[0] &= ~GBMap[PVGBButtonB];
        (gamepad.buttonB.isPressed || gamepad.buttonX.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonA] : gb_pad[0] &= ~GBMap[PVGBButtonA];

        (gamepad.leftShoulder.isPressed || gamepad.leftTrigger.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonSelect] : gb_pad[0] &= ~GBMap[PVGBButtonSelect];
        (gamepad.rightShoulder.isPressed || gamepad.rightTrigger.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonStart] : gb_pad[0] &= ~GBMap[PVGBButtonStart];
    }
    else if ([self.controller1 gamepad])
    {
        GCGamepad *gamepad = [self.controller1 gamepad];
        GCControllerDirectionPad *dpad = [gamepad dpad];

        dpad.up.isPressed ? gb_pad[0] |= GBMap[PVGBButtonUp] : gb_pad[0] &= ~GBMap[PVGBButtonUp];
        dpad.down.isPressed ? gb_pad[0] |= GBMap[PVGBButtonDown] : gb_pad[0] &= ~GBMap[PVGBButtonDown];
        dpad.left.isPressed ? gb_pad[0] |= GBMap[PVGBButtonLeft] : gb_pad[0] &= ~GBMap[PVGBButtonLeft];
        dpad.right.isPressed ? gb_pad[0] |= GBMap[PVGBButtonRight] : gb_pad[0] &= ~GBMap[PVGBButtonRight];

        (gamepad.buttonA.isPressed || gamepad.buttonY.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonB] : gb_pad[0] &= ~GBMap[PVGBButtonB];
        (gamepad.buttonB.isPressed || gamepad.buttonX.isPressed) ? gb_pad[0] |= GBMap[PVGBButtonA] : gb_pad[0] &= ~GBMap[PVGBButtonA];

        gamepad.leftShoulder.isPressed ? gb_pad[0] |= GBMap[PVGBButtonSelect] : gb_pad[0] &= ~GBMap[PVGBButtonSelect];
        gamepad.rightShoulder.isPressed ? gb_pad[0] |= GBMap[PVGBButtonStart] : gb_pad[0] &= ~GBMap[PVGBButtonStart];
    }
#if TARGET_OS_TV
    else if ([self.controller1 microGamepad])
    {
        GCMicroGamepad *pad = [self.controller1 microGamepad];
        GCControllerDirectionPad *dpad = [pad dpad];

        dpad.up.value > 0.5 ? gb_pad[0] |= GBMap[PVGBButtonUp] : gb_pad[0] &= ~GBMap[PVGBButtonUp];
        dpad.down.value > 0.5 ? gb_pad[0] |= GBMap[PVGBButtonDown] : gb_pad[0] &= ~GBMap[PVGBButtonDown];
        dpad.left.value > 0.5 ? gb_pad[0] |= GBMap[PVGBButtonLeft] : gb_pad[0] &= ~GBMap[PVGBButtonLeft];
        dpad.right.value > 0.5 ? gb_pad[0] |= GBMap[PVGBButtonRight] : gb_pad[0] &= ~GBMap[PVGBButtonRight];

        pad.buttonA.isPressed ? gb_pad[0] |= GBMap[PVGBButtonB] : gb_pad[0] &= ~GBMap[PVGBButtonB];
        pad.buttonX.isPressed ? gb_pad[0] |= GBMap[PVGBButtonA] : gb_pad[0] &= ~GBMap[PVGBButtonA];
    }
#endif
}

#pragma mark - Cheats

NSMutableDictionary *gb_cheatlist = [[NSMutableDictionary alloc] init];

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Gambatte expects cheats UPPERCASE
    code = [code uppercaseString];

    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (enabled)
        [gb_cheatlist setValue:@YES forKey:code];
    else
        [gb_cheatlist removeObjectForKey:code];

    NSMutableArray *combinedGameSharkCodes = [[NSMutableArray alloc] init];
    NSMutableArray *combinedGameGenieCodes = [[NSMutableArray alloc] init];

    // Gambatte expects all cheats in one combined string per-type e.g. 01xxxxxx+01xxxxxx
    // Add enabled per-type cheats to arrays and later join them all by a '+' separator
    for (id key in gb_cheatlist)
    {
        if ([[gb_cheatlist valueForKey:key] isEqual:@YES])
        {
            // GameShark
            if ([key rangeOfString:@"-"].location == NSNotFound)
                [combinedGameSharkCodes addObject:key];
            // Game Genie
            else if ([key rangeOfString:@"-"].location != NSNotFound)
                [combinedGameGenieCodes addObject:key];
        }
    }

    // Apply combined cheats or force a final reset if all cheats are disabled
    [self applyCheat:[combinedGameSharkCodes count] != 0 ? [combinedGameSharkCodes componentsJoinedByString:@"+"] : @"0"];
    [self applyCheat:[combinedGameGenieCodes count] != 0 ? [combinedGameGenieCodes componentsJoinedByString:@"+"] : @"0-"];
}

# pragma mark - Display Mode
- (GBPalette)currentDisplayMode {
	return displayMode;
}

- (void)changeDisplayMode:(GBPalette)displayMode
{
    if (gb.isCgb()) {
        return;
    }

    unsigned short *gbc_bios_palette = NULL;
	self->displayMode = displayMode;
    switch (displayMode)
    {
        case GBPalettePeaSoupGreen:
        {
            // GB Pea Soup Green
            gb.setDmgPaletteColor(0, 0, 8369468);
            gb.setDmgPaletteColor(0, 1, 6728764);
            gb.setDmgPaletteColor(0, 2, 3629872);
            gb.setDmgPaletteColor(0, 3, 3223857);
            gb.setDmgPaletteColor(1, 0, 8369468);
            gb.setDmgPaletteColor(1, 1, 6728764);
            gb.setDmgPaletteColor(1, 2, 3629872);
            gb.setDmgPaletteColor(1, 3, 3223857);
            gb.setDmgPaletteColor(2, 0, 8369468);
            gb.setDmgPaletteColor(2, 1, 6728764);
            gb.setDmgPaletteColor(2, 2, 3629872);
            gb.setDmgPaletteColor(2, 3, 3223857);
            return;
        }
        case GBPalettePocket:
        {
            // GB Pocket
            gb.setDmgPaletteColor(0, 0, 13487791);
            gb.setDmgPaletteColor(0, 1, 10987158);
            gb.setDmgPaletteColor(0, 2, 6974033);
            gb.setDmgPaletteColor(0, 3, 2828823);
            gb.setDmgPaletteColor(1, 0, 13487791);
            gb.setDmgPaletteColor(1, 1, 10987158);
            gb.setDmgPaletteColor(1, 2, 6974033);
            gb.setDmgPaletteColor(1, 3, 2828823);
            gb.setDmgPaletteColor(2, 0, 13487791);
            gb.setDmgPaletteColor(2, 1, 10987158);
            gb.setDmgPaletteColor(2, 2, 6974033);
            gb.setDmgPaletteColor(2, 3, 2828823);

            return;
        }
        case GBPaletteBlue:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Blue"));
            break;
        case GBPaletteDarkBlue:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Dark Blue"));
            break;
        case GBPaletteGreen:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Green"));
            break;
        case GBPaletteDarkGreen:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Dark Green"));
            break;
        case GBPaletteBrown:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Brown"));
            break;
        case GBPaletteDarkBrown:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Dark Brown"));
            break;
        case GBPaletteRed:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Red"));
            break;
        case GBPaletteYellow:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Yellow"));
            break;
        case GBPaletteOrange:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Orange"));
            break;
        case GBPalettePastelMix:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Pastel Mix"));
            break;
        case GBPaletteInverted:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Inverted"));
            break;
		case GBPaletteRomTitle:
        {
            std::string str = gb.romTitle(); // read ROM internal title
            const char *internal_game_name = str.c_str();
            gbc_bios_palette = const_cast<unsigned short *>(findGbcTitlePal(internal_game_name));

            if (gbc_bios_palette == 0)
            {
                gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Grayscale"));
            }
			break;
		}
        case GBPaletteGrayscale:
            gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Grayscale"));
			break;
        default:
            return;
			break;
	}

    unsigned rgb32 = 0;
    for (unsigned palnum = 0; palnum < 3; ++palnum)
    {
        for (unsigned colornum = 0; colornum < 4; ++colornum)
        {
            rgb32 = gbcToRgb32(gbc_bios_palette[palnum * 4 + colornum]);
            gb.setDmgPaletteColor(palnum, colornum, rgb32);
        }
    }
}

# pragma mark - Misc Helper Methods

- (void)outputAudio:(unsigned)frames
{
    if (!frames)
        return;

    size_t len = resampler->resample(outSoundBuffer, reinterpret_cast<const int16_t *>(inSoundBuffer), frames);

    if (len)
        [[self ringBufferAtIndex:0] write:outSoundBuffer maxLength:len << 2];
}

- (void)applyCheat:(NSString *)code
{
    std::string s = [code UTF8String];
    if (s.find("-") != std::string::npos)
        gb.setGameGenie(s);
    else
        gb.setGameShark(s);
}

- (void)loadPalette
{
    std::string str = gb.romTitle(); // read ROM internal title
    const char *internal_game_name = str.c_str();

    // load a GBC BIOS builtin palette
    unsigned short *gbc_bios_palette = NULL;
    gbc_bios_palette = const_cast<unsigned short *>(findGbcTitlePal(internal_game_name));

    if (gbc_bios_palette == 0)
    {
        // no custom palette found, load the default (Original Grayscale)
        gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal("GBC - Grayscale"));
    }

    unsigned rgb32 = 0;
    for (unsigned palnum = 0; palnum < 3; ++palnum)
    {
        for (unsigned colornum = 0; colornum < 4; ++colornum)
        {
            rgb32 = gbcToRgb32(gbc_bios_palette[palnum * 4 + colornum]);
            gb.setDmgPaletteColor(palnum, colornum, rgb32);
        }
    }
}

@end
