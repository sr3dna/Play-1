/*
 *  $Id$
 *
 *  Copyright (C) 2007 Stephen F. Booth <me@sbooth.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "ScheduledAudioRegion.h"
#import "AudioDecoder.h"

void allocate_slice_for_asbd(const AudioStreamBasicDescription *asbd, ScheduledAudioSlice *slice, NSUInteger numberOfFramesPerSlice);
void deallocate_slice(ScheduledAudioSlice *slice);
ScheduledAudioSlice * allocate_slice_buffer_for_asbd(const AudioStreamBasicDescription *asbd, NSUInteger numberOfSlicesInBuffer, NSUInteger numberOfFramesPerSlice);
void deallocate_slice_buffer(ScheduledAudioSlice **sliceBuffer, NSArray<NSLock *> *sliceLocks, NSUInteger numberOfSlicesInBuffer);

// ========================================
// Helper functions
// ========================================
void
allocate_slice_for_asbd(const AudioStreamBasicDescription *asbd, ScheduledAudioSlice *slice, NSUInteger numberOfFramesPerSlice)
{
	NSCParameterAssert(NULL != asbd);
	NSCParameterAssert(NULL != slice);
	NSCParameterAssert(0 < numberOfFramesPerSlice);
	
	// Allocate the buffer list
	slice->mBufferList = calloc(sizeof(AudioBufferList) + (sizeof(AudioBuffer) * (asbd->mChannelsPerFrame - 1)), 1);
	NSCAssert(NULL != slice->mBufferList, @"Unable to allocate memory");
	
	slice->mBufferList->mNumberBuffers = asbd->mChannelsPerFrame;
	
	NSUInteger i;
	for(i = 0; i < slice->mBufferList->mNumberBuffers; ++i) {
		slice->mBufferList->mBuffers[i].mData = calloc(numberOfFramesPerSlice, sizeof(float));
		NSCAssert(NULL != slice->mBufferList->mBuffers[i].mData, @"Unable to allocate memory");
		slice->mBufferList->mBuffers[i].mDataByteSize = numberOfFramesPerSlice * sizeof(float);
		slice->mBufferList->mBuffers[i].mNumberChannels = 1;
	}
	
	// Set the complete flag so the scheduler knows this slice can be filled and scheduled
	slice->mFlags = kScheduledAudioSliceFlag_Complete;
}

void
deallocate_slice(ScheduledAudioSlice *slice)
{
	NSCParameterAssert(NULL != slice);
	
	NSUInteger i;
	for(i = 0; i < slice->mBufferList->mNumberBuffers; ++i) {
		free(slice->mBufferList->mBuffers[i].mData);
		slice->mBufferList->mBuffers[i].mData = NULL;
	}
	
	free(slice->mBufferList);
	slice->mBufferList = NULL;
}

ScheduledAudioSlice *
allocate_slice_buffer_for_asbd(const AudioStreamBasicDescription *asbd, NSUInteger numberOfSlicesInBuffer, NSUInteger numberOfFramesPerSlice)
{
	NSCParameterAssert(NULL != asbd);
	NSCParameterAssert(0 < numberOfSlicesInBuffer);
	NSCParameterAssert(0 < numberOfFramesPerSlice);
	
	ScheduledAudioSlice *sliceBuffer = calloc(numberOfSlicesInBuffer, sizeof(ScheduledAudioSlice));
	NSCAssert(NULL != sliceBuffer, @"Unable to allocate memory");
	
	NSUInteger i;
	for(i = 0; i < numberOfSlicesInBuffer; ++i)
		allocate_slice_for_asbd(asbd, sliceBuffer + i, numberOfFramesPerSlice);
	
	return sliceBuffer;
}

void
deallocate_slice_buffer(ScheduledAudioSlice **sliceBuffer, NSArray<NSLock *> *sliceLocks, NSUInteger numberOfSlicesInBuffer)
{
	NSCParameterAssert(NULL != sliceBuffer);
	NSCParameterAssert(0 < numberOfSlicesInBuffer);

	if(NULL == *sliceBuffer)
		return;
	
	NSUInteger i;
	for(i = 0; i < numberOfSlicesInBuffer; ++i) {
		[sliceLocks[i] lock];

		deallocate_slice(*sliceBuffer + i);
		
		[sliceLocks[i] unlock];
	}
	
	free(*sliceBuffer);
	*sliceBuffer = NULL;
}

static void
clear_buffer_list(AudioBufferList *bufferList, NSUInteger numberOfFramesPerSlice)
{
	NSCParameterAssert(NULL != bufferList);
	NSCParameterAssert(0 < numberOfFramesPerSlice);
	
	NSUInteger i;
	for(i = 0; i < bufferList->mNumberBuffers; ++i) {
		bufferList->mBuffers[i].mDataByteSize = numberOfFramesPerSlice * sizeof(float);
		memset(bufferList->mBuffers[i].mData, 0, bufferList->mBuffers[i].mDataByteSize);
	}
}

static void
clear_slice_buffer(ScheduledAudioSlice *sliceBuffer, NSArray<NSLock *> *sliceLocks, NSUInteger numberOfSlicesInBuffer, NSUInteger numberOfFramesPerSlice)
{
	NSCParameterAssert(NULL != sliceBuffer);
	NSCParameterAssert(0 < numberOfSlicesInBuffer);
	NSCParameterAssert(0 < numberOfFramesPerSlice);
	
	NSUInteger i, j;
	for(i = 0; i < numberOfSlicesInBuffer; ++i) {
		[sliceLocks[i] lock];
		
		for(j = 0; j < sliceBuffer[i].mBufferList->mNumberBuffers; ++j)
			clear_buffer_list(sliceBuffer[i].mBufferList, numberOfFramesPerSlice);
		sliceBuffer[i].mFlags = kScheduledAudioSliceFlag_Complete;
		
		[sliceLocks[i] unlock];
	}
}

@interface ScheduledAudioRegion ()

@property (atomic, readwrite, assign) SInt64 framesScheduled;
@property (atomic, readwrite, assign) SInt64 framesRendered;

@end

@implementation ScheduledAudioRegion

#pragma mark Creation

+ (ScheduledAudioRegion *) scheduledAudioRegionWithDecoder:(id <AudioDecoderMethods>)decoder
{
	return [[ScheduledAudioRegion alloc] initWithDecoder:decoder];
}

+ (ScheduledAudioRegion *) scheduledAudioRegionWithDecoder:(id <AudioDecoderMethods>)decoder startTime:(AudioTimeStamp)startTime
{
	return [[ScheduledAudioRegion alloc] initWithDecoder:decoder startTime:startTime];
}

- (id) initWithDecoder:(id <AudioDecoderMethods>)decoder
{
	if((self = [super init])) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
		AudioTimeStamp startTime = { 0 };
#pragma clang diagnostic pop
		
		startTime.mFlags		= kAudioTimeStampSampleTimeValid;
		startTime.mSampleTime	= 0;
		
		[self setDecoder:decoder];
		[self setStartTime:startTime];
	}
	return self;
}

- (id) initWithDecoder:(id <AudioDecoderMethods>)decoder startTime:(AudioTimeStamp)startTime
{
	if((self = [super init])) {
		[self setDecoder:decoder];
		[self setStartTime:startTime];
	}
	return self;
}

- (void) dealloc
{
	deallocate_slice_buffer(&_sliceBuffer, _sliceLocks, [self numberOfSlicesInBuffer]);
}

#pragma mark Properties

- (AudioTimeStamp)	startTime								{ return _startTime; }

- (void) setStartTime:(AudioTimeStamp)startTime
{
	NSParameterAssert(kAudioTimeStampSampleTimeValid & startTime.mFlags);
	
	_startTime = startTime;
}

/*
- (id <AudioDecoderMethods>)	decoder						{ return _decoder; }

- (void) setDecoder:(id <AudioDecoderMethods>)decoder
{
	NSParameterAssert(nil != decoder);
	NSParameterAssert(kAudioFormatFlagsNativeFloatPacked & [decoder format].mFormatFlags);
	NSParameterAssert(kAudioFormatFlagIsNonInterleaved & [decoder format].mFormatFlags);
	
	_decoder = decoder;	
}
*/

- (BOOL)			atEnd									{ return _atEnd; }

- (NSUInteger) numberOfSlicesInBuffer
{
	return _numberSlices;
}

- (NSUInteger) numberOfFramesPerSlice
{
	return _framesPerSlice;
}

- (void) allocateBuffersWithSliceCount:(NSUInteger)sliceCount frameCount:(NSUInteger)frameCount
{
	NSParameterAssert(0 < sliceCount);
	NSParameterAssert(0 < frameCount);
	
	_numberSlices		= sliceCount;
	_framesPerSlice		= frameCount;
	
	// Allocate the buffers for the AudioScheduler to use
	deallocate_slice_buffer(&_sliceBuffer, _sliceLocks, [self numberOfSlicesInBuffer]);
	AudioStreamBasicDescription format = [[self decoder] format];
	_sliceBuffer = allocate_slice_buffer_for_asbd(&format, [self numberOfSlicesInBuffer], [self numberOfFramesPerSlice]);
	
	NSMutableArray *sliceLocks = [NSMutableArray arrayWithCapacity:sliceCount];
	for (NSUInteger i = 0; i < sliceCount; i += 1) {
		[sliceLocks addObject:[[NSLock alloc] init]];
	}
	_sliceLocks = [sliceLocks copy];
}

- (void) lockSlice:(NSUInteger)sliceIndex;
{
	NSParameterAssert(sliceIndex < [self numberOfSlicesInBuffer]);

	[_sliceLocks[sliceIndex] lock];
}

- (void) lockSliceWithReference:(ScheduledAudioSlice *)slice;
{
	ptrdiff_t offset = slice - _sliceBuffer;
	NSUInteger sliceIndex = (NSUInteger)offset;
	
	//NSAssert(((_sliceBuffer + sliceIndex) == slice), @"Ref calc.");
	
	[self lockSlice:sliceIndex];
}

- (void) unlockSlice:(NSUInteger)sliceIndex;
{
	NSParameterAssert(sliceIndex < [self numberOfSlicesInBuffer]);

	[_sliceLocks[sliceIndex] unlock];
}

- (void) unlockSliceWithReference:(ScheduledAudioSlice *)slice;
{
	ptrdiff_t offset = slice - _sliceBuffer;
	NSUInteger sliceIndex = (NSUInteger)offset;
	
	//NSAssert(((_sliceBuffer + sliceIndex) == slice), @"Ref calc.");
	
	[self unlockSlice:sliceIndex];
}

- (void) clearSliceBuffer
{
	clear_slice_buffer(_sliceBuffer, _sliceLocks, [self numberOfSlicesInBuffer], [self numberOfFramesPerSlice]);
}

- (void) clearSlice:(NSUInteger)sliceIndex
{
	NSParameterAssert(sliceIndex < [self numberOfSlicesInBuffer]);

	clear_buffer_list(_sliceBuffer[sliceIndex].mBufferList, [self numberOfFramesPerSlice]);
}

- (void)			clearFramesScheduled					{ self.framesScheduled = 0; }
- (void)			clearFramesRendered						{ self.framesRendered = 0; }

- (UInt32) readAudioInSlice:(NSUInteger)sliceIndex
{
	NSParameterAssert(sliceIndex < [self numberOfSlicesInBuffer]);
	
	UInt32 framesRead = [[self decoder] readAudio:_sliceBuffer[sliceIndex].mBufferList frameCount:[self numberOfFramesPerSlice]];
	
	if(0 == framesRead)
		_atEnd = YES;
	
	return framesRead;
}

- (ScheduledAudioSlice *) buffer
{
	return _sliceBuffer;
}

- (ScheduledAudioSlice *) sliceAtIndex:(NSUInteger)sliceIndex
{
	NSParameterAssert(sliceIndex < [self numberOfSlicesInBuffer]);

	return _sliceBuffer + sliceIndex;
}

- (void) scheduledAdditionalFrames:(UInt32)frameCount
{
	self.framesScheduled += frameCount;
}

- (void) renderedAdditionalFrames:(UInt32)frameCount
{
	self.framesRendered += frameCount;
}

- (NSString *) description
{
	return [NSString stringWithFormat:@"%@ (%qi, %qi)", [self decoder], self.framesRendered, self.framesScheduled];
}

@end
