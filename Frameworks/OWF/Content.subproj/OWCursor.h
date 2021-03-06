// Copyright 1997-2005 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OmniFoundation/OFObject.h>

@class NSException;
@class OFInvocation, OFMessageQueue;

typedef enum {
    OWCursorSeekFromCurrent,
    OWCursorSeekFromEnd,
    OWCursorSeekFromStart
} OWCursorSeekPosition;

@interface OWCursor : OFObject
{
    NSException *abortException;
}

- (id)initFromCursor:(id)aCursor;
- (id)newCursor;

- (unsigned int)seekToOffset:(int)offset fromPosition:(OWCursorSeekPosition)position;
- (BOOL)isAtEOF;
- (void)abortWithException:(NSException *)anException;
- (void)abort;
    // Calls -abortWithException: passing userAbortException as the exception

- (void)scheduleInQueue:(OFMessageQueue *)aQueue invocation:(OFInvocation *)anInvocation;

@end
