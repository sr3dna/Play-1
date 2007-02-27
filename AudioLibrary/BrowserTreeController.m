/*
 *  $Id$
 *
 *  Copyright (C) 2005 - 2007 Stephen F. Booth <me@sbooth.org>
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

#import "BrowserTreeController.h"
#import "CollectionManager.h"
#import "AudioStreamManager.h"
#import "BrowserNode.h"
#import "PlaylistNode.h"
#import "LibraryNode.h"
#import "CurrentStreamsNode.h"
#import "WatchFolderNode.h"
#import "Playlist.h"

// ========================================
// Completely bogus NSTreeController bindings hack
// ========================================
@interface NSObject (NSTreeControllerBogosity)
- (id) observedObject;
@end

@implementation BrowserTreeController

// An outline view data source MUST implement these methods
// Just return 0 and nil to fall back to bindings
#pragma mark Required data source methods

- (int) outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	return 0;
}

- (BOOL) outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	return NO;
}

- (id) outlineView:(NSOutlineView *)outlineView child:(int)index ofItem:(id)item
{
	return nil;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	return nil;
}

#pragma mark Overrides

- (BOOL) canInsertPlaylist
{
	return [self canInsert];
}

- (BrowserNode *) selectedNode
{
	NSArray *selectedObjects = [self selectedObjects];

	return (0 == [selectedObjects count] ? nil : [selectedObjects objectAtIndex:0]);
}

- (BOOL) selectedNodeIsCurrentStreams
{
	return [[self selectedNode] isKindOfClass:[CurrentStreamsNode class]];
}

- (BOOL) selectedNodeIsLibrary
{
	return [[self selectedNode] isKindOfClass:[LibraryNode class]];
}

- (BOOL) selectedNodeIsPlaylist
{
	return [[self selectedNode] isKindOfClass:[PlaylistNode class]];
}

- (BOOL) selectedNodeIsWatchFolder
{
	return [[self selectedNode] isKindOfClass:[WatchFolderNode class]];
}

- (BOOL) canRemove
{
	NSEnumerator	*enumerator		= [[self selectedObjects] objectEnumerator];
	BrowserNode		*node			= nil;
	
	while((node = [enumerator nextObject])) {
		if(NO == [node isKindOfClass:[PlaylistNode class]] || NO == [node isKindOfClass:[CurrentStreamsNode class]]) {
			return NO;
		}
	}
	return YES;
}

- (BOOL) canInsert
{
	return YES;
}

#pragma mark Drag and Drop

- (NSDragOperation) outlineView:(NSOutlineView *)outlineView validateDrop:(id <NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(int)index
{
	BrowserNode *node = [item observedObject];
	
	return ([node isKindOfClass:[PlaylistNode class]] || [node isKindOfClass:[CurrentStreamsNode class]] ? NSDragOperationCopy : NSDragOperationNone);
}

- (BOOL) outlineView:(NSOutlineView *)outlineView acceptDrop:(id <NSDraggingInfo>)info item:(id)item childIndex:(int)index
{
	BrowserNode		*node		= [item observedObject];
	NSArray			*objectIDs	= [[info draggingPasteboard] propertyListForType:AudioStreamPboardType];

	if([node isKindOfClass:[PlaylistNode class]]) {
		[[(PlaylistNode *)node playlist] addStreamsWithIDs:objectIDs];		
		return YES;
	}
	if([node isKindOfClass:[CurrentStreamsNode class]]) {
		NSEnumerator	*enumerator		= [objectIDs objectEnumerator];
		NSNumber		*objectID		= nil;
		AudioStream		*stream			= nil;
		
		while((objectID = [enumerator nextObject])) {
			stream = [[[CollectionManager manager] streamManager] streamForID:objectID];
			[(CurrentStreamsNode *)node insertObject:stream inStreamsAtIndex:[(CurrentStreamsNode *)node countOfStreams]];
		}
		
		return YES;
	}
		
	return NO;
}

@end
