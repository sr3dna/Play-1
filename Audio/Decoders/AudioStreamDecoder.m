/*
 *  $Id$
 *
 *  Copyright (C) 2006 Stephen F. Booth <me@sbooth.org>
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

// ========================================
// A very special thanks to Kurt Revis <krevis@snoize.com> for his 
// help and code- most of the multi-threading code in this file comes
// from his PlayBufferedSoundFile
// ========================================

#import "AudioStreamDecoder.h"
#import "FLACStreamDecoder.h"
#import "OggVorbisStreamDecoder.h"
#import "MusepackStreamDecoder.h"
#import "CoreAudioStreamDecoder.h"

#import "UtilityFunctions.h"

#import <mach/mach_error.h>
#import <mach/mach_time.h>

#include <AudioToolbox/AudioFormat.h>

NSString *const AudioStreamDecoderErrorDomain = @"org.sbooth.Play.ErrorDomain.AudioStreamDecoder";

@interface AudioStreamDecoder (Private)

- (semaphore_t)			semaphore;

- (BOOL)				keepProcessingFile;
- (void)				setKeepProcessingFile:(BOOL)keepProcessingFile;

- (void)				fillRingBufferInThread:(AudioStreamDecoder *)myself;
- (void)				setThreadPolicy;

@end

@implementation AudioStreamDecoder

+ (void) initialize
{
	[self exposeBinding:@"currentFrame"];
	[self exposeBinding:@"totalFrames"];
	[self exposeBinding:@"framesRemaining"];
	
	[self setKeys:[NSArray arrayWithObject:@"framesRemaining"] triggerChangeNotificationsForDependentKey:@"currentFrame"];
	[self setKeys:[NSArray arrayWithObject:@"framesRemaining"] triggerChangeNotificationsForDependentKey:@"totalFrames"];
}

+ (AudioStreamDecoder *) streamDecoderForURL:(NSURL *)url error:(NSError **)error
{
	NSParameterAssert(nil != url);
	NSParameterAssert([url isFileURL]);
	
	AudioStreamDecoder				*result;
	NSString						*path;
	NSString						*pathExtension;
	
	path							= [url path];
	pathExtension					= [[path pathExtension] lowercaseString];
	
	if([pathExtension isEqualToString:@"flac"]) {
		result						= [[FLACStreamDecoder alloc] init];
		
		[result setValue:url forKey:@"url"];
	}
	else if([pathExtension isEqualToString:@"ogg"]) {
		result						= [[OggVorbisStreamDecoder alloc] init];
		
		[result setValue:url forKey:@"url"];
	}
	else if([pathExtension isEqualToString:@"mpc"]) {
		result						= [[MusepackStreamDecoder alloc] init];
		
		[result setValue:url forKey:@"url"];
	}
	else if([getCoreAudioExtensions() containsObject:pathExtension]) {
		result						= [[CoreAudioStreamDecoder alloc] init];
		
		[result setValue:url forKey:@"url"];
	}
	else {
		if(nil != error) {
			NSMutableDictionary		*errorDictionary;
			
			errorDictionary			= [NSMutableDictionary dictionary];
			
			[errorDictionary setObject:[NSString stringWithFormat:@"The format of the file \"%@\" was not recognized.", [path lastPathComponent]] forKey:NSLocalizedDescriptionKey];
			[errorDictionary setObject:@"File Format Not Recognized" forKey:NSLocalizedFailureReasonErrorKey];
			[errorDictionary setObject:@"The file's extension may not match the file's type." forKey:NSLocalizedRecoverySuggestionErrorKey];
			
			*error					= [NSError errorWithDomain:AudioStreamDecoderErrorDomain 
														  code:AudioStreamDecoderFileFormatNotRecognizedError 
													  userInfo:errorDictionary];
		}
		
		result						= nil;
	}
	
	return [result autorelease];
}

- (id) init
{
	if((self = [super init])) {
		kern_return_t	result;

		_pcmBuffer		= [(VirtualRingBuffer *)[VirtualRingBuffer alloc] initWithLength:RING_BUFFER_SIZE];
		result			= semaphore_create(mach_task_self(), &_semaphore, SYNC_POLICY_FIFO, 0);
		
		if(KERN_SUCCESS != result) {
#if DEBUG
			mach_error("Couldn't create semaphore", error);
#endif
			[self release];
			return nil;
		}
		
		return self;
	}
	return nil;
}

- (void) dealloc
{
	[_pcmBuffer release];		_pcmBuffer = nil;

	semaphore_destroy(mach_task_self(), _semaphore);	_semaphore = 0;

	[super dealloc];
}

- (AudioStreamBasicDescription)		pcmFormat			{ return _pcmFormat; }
- (VirtualRingBuffer *)				pcmBuffer			{ return [[_pcmBuffer retain] autorelease]; }

- (NSString *)						pcmFormatDescription
{
	OSStatus						result;
	UInt32							specifierSize;
	AudioStreamBasicDescription		asbd;
	NSString						*fileFormat;
	
	asbd			= _pcmFormat;
	specifierSize	= sizeof(fileFormat);
	result			= AudioFormatGetProperty(kAudioFormatProperty_FormatName, sizeof(AudioStreamBasicDescription), &asbd, &specifierSize, &fileFormat);
	NSAssert1(noErr == result, @"AudioFormatGetProperty failed: %@", UTCreateStringForOSType(result));
	
	return [fileFormat autorelease];
}

- (UInt32) readAudio:(AudioBufferList *)bufferList frameCount:(UInt32)frameCount
{
	NSParameterAssert(NULL != bufferList);
	NSParameterAssert(1 == bufferList->mNumberBuffers);
	NSParameterAssert(0 < frameCount);
	
	UInt32							framesRead;
	UInt32							bytesToRead, bytesAvailable;
	void							*readPointer;

    bytesAvailable					= [[self pcmBuffer] lengthAvailableToReadReturningPointer:&readPointer];

	if(bytesAvailable >= bufferList->mBuffers[0].mDataByteSize) {
		bytesToRead					= bufferList->mBuffers[0].mDataByteSize;
	}
	else {
		bytesToRead					= bytesAvailable;

		// Zero the portion of the buffer we can't fill
		bzero(bufferList->mBuffers[0].mData + bytesToRead, bufferList->mBuffers[0].mDataByteSize - bytesToRead);
	}

	// Copy the decoded data to the output buffer
	if(0 < bytesToRead) {
		memcpy(bufferList->mBuffers[0].mData, readPointer, bytesToRead);
		[[self pcmBuffer] didReadLength:bytesToRead];
	}

	// If there is now enough space available to write into the ring buffer, wake up the feeder thread.
	if((RING_BUFFER_SIZE - RING_BUFFER_WRITE_CHUNK_SIZE) > bytesAvailable) {
		semaphore_signal([self semaphore]);
	}
	
//	bufferList->mBuffers[0].mNumberChannels	= [self pcmFormat].mChannelsPerFrame;
	bufferList->mBuffers[0].mDataByteSize	= bytesToRead;
	framesRead								= bytesToRead / [self pcmFormat].mBytesPerFrame;
	
	[self setCurrentFrame:[self currentFrame] + framesRead];
			
	return framesRead;
}

- (NSString *)		sourceFormatDescription					{ return nil; }

- (SInt64)			totalFrames								{ return _totalFrames; }
- (SInt64)			currentFrame							{ return _currentFrame; }
- (SInt64)			framesRemaining 						{ return ([self totalFrames] - [self currentFrame]); }

- (SInt64) seekToFrame:(SInt64)frame
{	
	SInt64						result;
	
	result						= [self performSeekToFrame:frame]; 
	
	if(-1 != result) {
		[[self pcmBuffer] empty]; 
		[self setCurrentFrame:frame];
		[self setAtEndOfStream:NO];
	}
	
	return result;	
}

- (BOOL)							atEndOfStream			{ return _atEndOfStream; }

- (void) setAtEndOfStream:(BOOL)atEndOfStream
{
	_atEndOfStream = atEndOfStream;
}


// ========================================
// Decoder control
// ========================================
- (void) startDecoding:(NSError **)error
{
	[self setupDecoder];
	
	[[self pcmBuffer] empty];
	[self setKeepProcessingFile:YES];
	
	[NSThread detachNewThreadSelector:@selector(fillRingBufferInThread:) toTarget:self withObject:self];
}

- (void) stopDecoding:(NSError **)error
{
	[self setKeepProcessingFile:NO];
	[self cleanupDecoder];
}

// ========================================
// Subclass stubs
// ========================================
- (SInt64)			performSeekToFrame:(SInt64)frame		{ return -1; }

- (void)			fillPCMBuffer							{}
- (void)			setupDecoder							{}
- (void)			cleanupDecoder							{}

// ========================================
// KVC
// ========================================
- (void)			setTotalFrames:(SInt64)totalFrames		{ _totalFrames = totalFrames; }
- (void)			setCurrentFrame:(SInt64)currentFrame	{ _currentFrame = currentFrame; }

@end

@implementation AudioStreamDecoder (Private)

- (semaphore_t) semaphore
{
	return _semaphore;
}

- (BOOL) keepProcessingFile
{
	return _keepProcessingFile;
}

- (void) setKeepProcessingFile:(BOOL)keepProcessingFile
{
	_keepProcessingFile = keepProcessingFile;
}

// ========================================
// File reading thread
// ========================================
- (void) fillRingBufferInThread:(AudioStreamDecoder *)myself
{
	NSAutoreleasePool		*pool				= [[NSAutoreleasePool alloc] init];
	mach_timespec_t			timeout				= { 2, 0 };

	[myself setThreadPolicy];

	// Process the file
	while(YES == [myself keepProcessingFile] && NO == [myself atEndOfStream]) {
		[myself fillPCMBuffer];				

		// Wait for the audio thread to signal us that it could use more data, or for the timeout to happen
		semaphore_timedwait([myself semaphore], timeout);
	}

	[pool release];
}

- (void) setThreadPolicy
{
	kern_return_t						result;
	thread_extended_policy_data_t		extendedPolicy;
	thread_precedence_policy_data_t		precedencePolicy;

	extendedPolicy.timeshare			= 0;
	result								= thread_policy_set(mach_thread_self(), THREAD_EXTENDED_POLICY,  (thread_policy_t)&extendedPolicy, THREAD_EXTENDED_POLICY_COUNT);
	
	if(KERN_SUCCESS != result) {
#if DEBUG
		mach_error("Couldn't set producer thread's extended policy", error);
#endif
	}

	precedencePolicy.importance			= 6;
	result								= thread_policy_set(mach_thread_self(), THREAD_PRECEDENCE_POLICY, (thread_policy_t)&precedencePolicy, THREAD_PRECEDENCE_POLICY_COUNT);

	if(KERN_SUCCESS != result) {
#if DEBUG
		mach_error("Couldn't set producer thread's precedence policy", error);
#endif
	}
}

@end
