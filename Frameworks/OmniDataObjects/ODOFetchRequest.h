// Copyright 2008 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OmniFoundation/OFObject.h>

#import <OmniDataObjects/ODOPredicate.h> // For target-specific setup

@class NSArray;
@class ODOEntity;

@interface ODOFetchRequest : OFObject
{
@private
    ODOEntity *_entity;
    NSPredicate *_predicate;
    NSArray *_sortDescriptors;
    NSString *_reason;
}

- (void)setEntity:(ODOEntity *)entity;
- (ODOEntity *)entity;

- (void)setPredicate:(NSPredicate *)predicate;
- (NSPredicate *)predicate;

- (void)setSortDescriptors:(NSArray *)sortDescriptors;
- (NSArray *)sortDescriptors;

- (void)setReason:(NSString *)reason;
- (NSString *)reason;

@end
