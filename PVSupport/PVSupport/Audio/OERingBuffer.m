/*
 Copyright (c) 2009, OpenEmu Team

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

#import "OERingBuffer.h"

@implementation OERingBuffer
@synthesize bytesWritten;
@synthesize bytesRead;

- (instancetype)init {
    return [self initWithLength:1];
}

- (id)initWithLength:(uint32_t)length {
    if((self = [super init]))
    {
        TPCircularBufferInit(&buffer, length);
    }
    return self;
}

- (void)dealloc {
    TPCircularBufferCleanup(&buffer);
}

- (uint32_t)length {
    return buffer.length;
}

- (void)setLength:(uint32_t)length {
    TPCircularBufferCleanup(&buffer);
    TPCircularBufferInit(&buffer, length);
}

- (uint32_t)write:(const void *)inBuffer maxLength:(uint32_t)length {
    if (inBuffer == nil) {
        return 0;
    }
    bytesWritten += length;
    return TPCircularBufferProduceBytes(&buffer, inBuffer, length);
}

- (uint32_t)read:(void *)outBuffer maxLength:(uint32_t)len {
    uint32_t availableBytes = 0;
    void *head = TPCircularBufferTail(&buffer, &availableBytes);
    availableBytes = MIN(availableBytes, len);
    memcpy(outBuffer, head, availableBytes);
    TPCircularBufferConsume(&buffer, availableBytes);
	bytesRead += availableBytes;
    return availableBytes;
}

- (uint32_t)availableBytes {
    uint32_t availableBytes = 0;
    TPCircularBufferHead(&buffer, &availableBytes);
    return availableBytes;
}

- (uint32_t)usedBytes
{
    return buffer.length - buffer.fillCount;
}

@end
