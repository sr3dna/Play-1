/*
 *  $Id$
 *
 *  Copyright (C) 2006 - 2007 Stephen F. Booth <me@sbooth.org>
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

#import "ComposersNode.h"
#import "CollectionManager.h"
#import "AudioStreamManager.h"
#import "AudioStream.h"
#import "AudioLibrary.h"
#import "ComposerNode.h"

@interface ComposersNode (Private)
- (void) streamsChanged:(NSNotification *)aNotification;
- (void) loadChildren;
@end

@implementation ComposersNode

- (id) init
{
	if((self = [super initWithName:NSLocalizedStringFromTable(@"Composers", @"Library", @"")])) {
		[self loadChildren];
		
		[[[CollectionManager manager] streamManager] addObserver:self 
													  forKeyPath:MetadataComposerKey
														 options:0
														 context:nil];

		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(streamsChanged:) 
													 name:AudioStreamAddedToLibraryNotification
												   object:nil];
		
		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(streamsChanged:) 
													 name:AudioStreamsAddedToLibraryNotification
												   object:nil];
		
		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(streamsChanged:) 
													 name:AudioStreamRemovedFromLibraryNotification
												   object:nil];
		
		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(streamsChanged:) 
													 name:AudioStreamsRemovedFromLibraryNotification
												   object:nil];
		
	}
	return self;
}

- (void) dealloc
{
	[[[CollectionManager manager] streamManager] removeObserver:self forKeyPath:MetadataComposerKey];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	[self loadChildren];
}

@end

@implementation ComposersNode (Private)

- (void) streamsChanged:(NSNotification *)aNotification
{
	[self loadChildren];
}

- (void) loadChildren
{
	NSString		*keyName		= [NSString stringWithFormat:@"@distinctUnionOfObjects.%@", MetadataComposerKey];
	NSArray			*streams		= [[[CollectionManager manager] streamManager] streams];
	NSArray			*composers		= [[streams valueForKeyPath:keyName] sortedArrayUsingSelector:@selector(compare:)];
	ComposerNode	*node			= nil;
	
	[self willChangeValueForKey:@"children"];
	
	[_children makeObjectsPerformSelector:@selector(setParent:) withObject:nil];
	[_children removeAllObjects];
	for(NSString *composer in composers) {
		node = [[ComposerNode alloc] initWithName:composer];
		[node setParent:self];
		[_children addObject:node];
	}
	
	[self didChangeValueForKey:@"children"];
}

@end
