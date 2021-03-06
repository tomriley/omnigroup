// Copyright 2008 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OmniDataObjects/ODOModel.h>

@class ODODatabase;

@interface ODOModel (SQL)
- (BOOL)_createSchemaInDatabase:(ODODatabase *)database error:(NSError **)outError;
@end
