// Copyright 1997-2005 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OWF/OWCursor.h>

@class OWAbstractObjectStream;

@interface OWObjectStreamCursor : OWCursor <NSCopying>
{
    OWAbstractObjectStream *objectStream;
    void *hint;
    unsigned int streamIndex;
}

- initForObjectStream:(OWAbstractObjectStream *)anObjectStream;
- (OWAbstractObjectStream *)objectStream;
- (unsigned int)streamIndex;

- (id)readObject;
- (void)skipObjects:(int)count;
- (void)ungetObject:(id)anObject;

@end
