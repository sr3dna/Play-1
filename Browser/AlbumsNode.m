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

#import "AlbumsNode.h"
#import "CollectionManager.h"
#import "AudioStreamManager.h"
#import "AudioStream.h"
#import "AlbumNode.h"

@interface AlbumsNode (Private)
- (void) loadChildren;
@end

@implementation AlbumsNode

- (id) init
{
	if((self = [super initWithName:NSLocalizedStringFromTable(@"Albums", @"General", @"")])) {
		[self loadChildren];
		[[[CollectionManager manager] streamManager] addObserver:self 
													  forKeyPath:MetadataAlbumTitleKey
														 options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew)
														 context:nil];
	}
	return self;
}

- (void) dealloc
{
	[[[CollectionManager manager] streamManager] removeObserver:self forKeyPath:MetadataAlbumTitleKey];
	
	[super dealloc];
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	NSArray			*old 		= [change valueForKey:NSKeyValueChangeOldKey];
	NSArray			*new 		= [change valueForKey:NSKeyValueChangeNewKey];
	BOOL			needsSort	= NO;
	
	// Remove any modified nodes with empty streams from our children
	NSEnumerator 	*enumerator 	= nil;
	NSString 		*album			= nil;
	BrowserNode 	*node 			= nil;
	
	if(0 != [old count]) {
		enumerator = [old objectEnumerator];
		while((album = [enumerator nextObject])) {
			node = [self findChildWithName:album];
			if([node isKindOfClass:[AudioStreamCollectionNode class]]) {
				[(AudioStreamCollectionNode *)node refreshStreams];
				if(0 == [(AudioStreamCollectionNode *)node countOfStreams]) {
					[self removeChild:node];
					needsSort = YES;
				}
			}
		}
	}
	
	// Add the new albums
	if(0 != [new count]) {
		enumerator = [new objectEnumerator];
		while((album = [enumerator nextObject])) {
			node = [self findChildWithName:album];

			if(nil == node) {
				node = [[AlbumNode alloc] initWithName:album];
				[self addChild:[node autorelease]];
				node = nil;
				needsSort = YES;
			}
		}
	}
	
	if(needsSort) {
		[self sortChildren];
	}
}


@end

@implementation AlbumsNode (Private)

- (void) loadChildren
{
	NSArray			*albums			= [[[CollectionManager manager] streamManager] valueForKey:MetadataAlbumTitleKey];
	NSEnumerator	*enumerator		= [albums objectEnumerator];
	NSString		*album			= nil;
	AlbumNode		*node			= nil;
	
	[self willChangeValueForKey:@"children"];
	[_children makeObjectsPerformSelector:@selector(setParent:) withObject:nil];
	[_children removeAllObjects];
	while((album = [enumerator nextObject])) {
		node = [[AlbumNode alloc] initWithName:album];
		[node setParent:self];
		[_children addObject:[node autorelease]];
	}
	[self didChangeValueForKey:@"children"];
}

@end