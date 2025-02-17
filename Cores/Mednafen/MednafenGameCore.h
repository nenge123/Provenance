/*
 Copyright (c) 2013, OpenEmu Team
 
 
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

#import <Foundation/Foundation.h>
#import <PVSupport/PVEmulatorCore.h>

@class OERingBuffer;

typedef NS_ENUM(NSInteger, MednaSystem) {
	MednaSystemGB,
	MednaSystemGBA,
	MednaSystemGG,
    MednaSystemLynx,
	MednaSystemMD,
	MednaSystemNES,
    MednaSystemNeoGeo,
    MednaSystemPCE,
    MednaSystemPCFX,
    MednaSystemSS,
	MednaSystemSMS,
	MednaSystemSNES,
    MednaSystemPSX,
    MednaSystemVirtualBoy,
    MednaSystemWonderSwan
};

__attribute__((visibility("default")))
@interface MednafenGameCore : PVEmulatorCore

@property (nonatomic) BOOL isStartPressed;
@property (nonatomic) BOOL isSelectPressed;
@property (nonatomic) BOOL isAnalogModePressed;
@property (nonatomic) BOOL isL3Pressed;
@property (nonatomic) BOOL isR3Pressed;

@end

// for Swift
@interface MednafenGameCore()
@property (nonatomic, assign) MednaSystem systemType;
@property (nonatomic, assign) NSUInteger maxDiscs;
-(void)setMedia:(BOOL)open forDisc:(NSUInteger)disc;
-(void)changeDisplayMode;

# pragma CheatCodeSupport
- (BOOL)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled error:(NSError**)error;
- (BOOL)getCheatSupport;

#pragma mark - Options
@property (nonatomic, readonly) BOOL mednafen_pceFast;
@property (nonatomic, readonly) BOOL mednafen_snesFast;
@end
