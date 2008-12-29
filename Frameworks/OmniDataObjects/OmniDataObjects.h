// Copyright 2008 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Header: svn+ssh://source.omnigroup.com/Source/svn/Omni/tags/OmniSourceRelease/2008-09-09/OmniGroup/Frameworks/OmniDataObjects/OmniDataObjects.h 104581 2008-09-06 21:18:23Z kc $

#import <sys/types.h> // NSPredicate.h needs this =(

#import <OmniDataObjects/ODOPredicate.h> // Has some #defines to replace class names; get this first

#import <OmniDataObjects/ODOFeatures.h>
#import <OmniDataObjects/ODOAttribute.h>
#import <OmniDataObjects/ODOEntity.h>
#import <OmniDataObjects/ODOFetchRequest.h>
#import <OmniDataObjects/ODOObject.h>
#import <OmniDataObjects/ODOEditingContext.h>
#import <OmniDataObjects/ODOObjectID.h>
#import <OmniDataObjects/ODOModel.h>
#import <OmniDataObjects/ODODatabase.h>
#import <OmniDataObjects/ODOProperty.h>
#import <OmniDataObjects/ODORelationship.h>
#import <OmniDataObjects/Errors.h>
#import <OmniDataObjects/ODOVersion.h>
#import <OmniDataObjects/NSPredicate-ODOExtensions.h>