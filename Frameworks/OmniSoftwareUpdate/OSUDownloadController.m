// Copyright 2007-2009 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OSUDownloadController.h"

#import "OSUErrors.h"
#import "OSUInstaller.h"
#import "OSUItem.h"
#import "OSUSendFeedbackErrorRecovery.h"
#import "OSUPreferences.h"

#import <OmniAppKit/OAInternetConfig.h>
#import <OmniAppKit/NSAttributedString-OAExtensions.h>
#import <OmniAppKit/NSTextField-OAExtensions.h>
#import <OmniAppKit/NSView-OAExtensions.h>
#import <OmniAppKit/OAPreferenceController.h>
#import <OmniFoundation/OmniFoundation.h>

static BOOL OSUDebugDownload = NO;

// Preferences not manipulated through the preferences UI
#define UpgradeShowsOptionsPreferenceKey (@"OSUUpgradeShowsOptions")
#define UpgradeKeepsExistingVersionPreferenceKey (@"OSUUpgradeArchivesExistingVersion")
#define UpgradeKeepsPackagePreferenceKey (@"OSUUpgradeKeepsDiskImage")

#define DEBUG_DOWNLOAD(format, ...) \
do { \
    if (OSUDebugDownload) \
    NSLog((format), ## __VA_ARGS__); \
} while(0)

RCS_ID("$Id$");

static NSString * const OSUDownloadControllerStatusKey = @"status";
static NSString * const OSUDownloadControllerCurrentBytesDownloadedKey = @"currentBytesDownloaded";
static NSString * const OSUDownloadControllerTotalSizeKey = @"totalSize";
static NSString * const OSUDownloadControllerSizeKnownKey = @"sizeKnown";
static NSString * const OSUDownloadControllerInstallationDirectoryKey = @"installationDirectory";
static NSString * const OSUDownloadControllerInstallationDirectoryNoteKey = @"installationDirectoryNote";

static OSUDownloadController *CurrentDownloadController = nil;

@interface OSUDownloadController (Private)
- (void)_setInstallViews;
- (void)_setDisplayedView:(NSView *)aView;
- (void)setContentViews:(NSArray *)newContent;
- (void)_cancel;
@end

@implementation OSUDownloadController

+ (void)initialize;
{
    OBINITIALIZE;
    
    OSUDebugDownload = [[NSUserDefaults standardUserDefaults] boolForKey:@"OSUDebugDownload"];
}

+ (OSUDownloadController *)currentDownloadController;
{
    return CurrentDownloadController;
}

// Item might be nil if all we have is the URL (say, if the debugging support for downloading from a URL at launch is enabled).  *Usually* we'll have an item, but don't depend on it.
- initWithPackageURL:(NSURL *)packageURL item:(OSUItem *)item error:(NSError **)outError;
{
    if (![super init])
        return nil;

    // Only allow one download at a time for now.
    if (CurrentDownloadController) {
        // TODO: Add recovery options to cancel the existing download?
        NSString *description = NSLocalizedStringFromTableInBundle(@"A download is already in progress.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error description when trying to start a download when one is already in progress");
        NSString *suggestion = NSLocalizedStringFromTableInBundle(@"Please cancel the existing download before starting another.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error suggestion when trying to start a download when one is already in progress");
        OSUError(outError, OSUDownloadAlreadyInProgress, description, suggestion);
        return NO;
    }
    CurrentDownloadController = self;
    
    // Display a 'connecting' view here until we know whether we are going to be asked for credentials or not (and to allow cancelling).
    
    _rememberInKeychain = NO;
    _packageURL = [packageURL copy];
    _request = [[NSURLRequest requestWithURL:packageURL] retain];
    _item = [item retain];
    _showCautionText = NO;
    
    [self setInstallationDirectory:[OSUInstaller suggestAnotherInstallationDirectory:nil trySelf:YES]];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![[[NSBundle mainBundle] bundlePath] hasPrefix:_installationDirectory] &&
        ![defaults boolForKey:UpgradeKeepsExistingVersionPreferenceKey]) {
        
        // If we can't install over our current location, we probably can't delete the old copy either, so don't try.
        // We set "archives" to "yes" because "no" means "delete"
        // We really should have a better name for this flag (or maybe make it multivalued: leave alone, move to trash, move aside, make a zip file)
        
        // To avoid setting the preference for future sessions as well, put it in a new volatile domain
        // Also, it's probably an undesirable side effect that this sets the default for future updates as well as preventing us from trying to delete the old version on this update as well
        
        NSDictionary *cmdline = [defaults volatileDomainForName:NSArgumentDomain];
        cmdline = cmdline? [cmdline dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:UpgradeKeepsExistingVersionPreferenceKey] : [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:UpgradeKeepsExistingVersionPreferenceKey];
        [defaults setVolatileDomain:cmdline forName:NSArgumentDomain];
        
        OBASSERT([defaults boolForKey:UpgradeKeepsExistingVersionPreferenceKey]);
    }
    
    [self showWindow:nil];
    
    // This starts the download
    _download = [[NSURLDownload alloc] initWithRequest:_request delegate:self];
    
    // at least until we support resuming downloads, let's delete them on failure.
    // TODO: This doesn't delete the file when you cancel the download.
    [_download setDeletesFileUponFailure:YES];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:UpgradeShowsOptionsPreferenceKey options:0 context:[OSUDownloadController class]];
    
    return self;
}

- (void)dealloc;
{    
    [self _cancel]; // should have been done in -close, but just in case
    OBASSERT(_download == nil);
    OBASSERT(_challenge == nil);
    OBASSERT(_request == nil);
    OBASSERT(CurrentDownloadController != self); // cleared in _cancel
    
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:UpgradeShowsOptionsPreferenceKey];
    
    // _bottomView is embedded in our window and need not be released
    [_credentialsView release];
    [_progressView release];
    [_packageURL release];
    [_item release];
    
    [_suggestedDestinationFile release];
    [_destinationFile release];
    
    [super dealloc];
}

#pragma mark -
#pragma mark NSWindowController subclass

- (NSString *)windowNibName;
{
    return NSStringFromClass([self class]);
}

- (void)windowDidLoad;
{
    [super windowDidLoad];
    
    OBASSERT([_bottomView window] == [self window]);
    
    originalBottomViewSize = [_bottomView frame].size;
    originalWindowSize = [[[self window] contentView] frame].size;
    originalWarningViewSize = [_installWarningView frame].size;
    NSRect warningTextFrame = [_installViewCautionText frame];
    NSRect warningViewBounds = [_installWarningView bounds];
    originalWarningTextHeight = warningTextFrame.size.height;
    warningTextTopMargin = NSMaxY(warningViewBounds) - NSMaxY(warningTextFrame);

    OBASSERT([_installViewCautionText superview] == _installWarningView);
    OBASSERT([_installViewInstallButton superview] == _installButtonsView);
    OBASSERT([_installViewMessageText superview] == _installBasicView);

    NSString *name = [[[_request URL] path] lastPathComponent];
    [self setValue:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Downloading %@ \\U2026", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"Download status - text is filename of update package being downloaded"), name] forKey:OSUDownloadControllerStatusKey];
    
    [_installViewCautionText setStringValue:@"---"];
    [self _setDisplayedView:_plainStatusView];
    
    NSString *appDisplayName = [[NSProcessInfo processInfo] processName];
    [[self window] setTitle:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"%@ Update", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"Download window title - text is name of the running application"), appDisplayName]];
    
    NSString *basicText = [_installViewMessageText stringValue];
    basicText = [basicText stringByReplacingAllOccurrencesOfString:@"%@" withString:appDisplayName];
    [_installViewMessageText setStringValue:basicText];
}

#pragma mark -
#pragma mark NSWindow delegate

- (void)windowWillClose:(NSNotification *)notification;
{
    [self _cancel];
}

#pragma mark -
#pragma mark Actions

- (IBAction)cancelAndClose:(id)sender;
{
    [self close];
}

- (IBAction)continueDownloadWithCredentials:(id)sender;
{
    // We aren't a NSController, so we need to commit the editing...
    NSWindow *window = [self window];
    [window makeFirstResponder:window];
    
    NSURLCredential *credential = [[NSURLCredential alloc] initWithUser:_userName password:_password persistence:(_rememberInKeychain ? NSURLCredentialPersistencePermanent : NSURLCredentialPersistenceForSession)];
    [[_challenge sender] useCredential:credential forAuthenticationChallenge:_challenge];
    [credential release];

    // Switch views so that if we get another credential failure, the user sees that we *tried* to use what they gave us, but failed again.
    [self _setDisplayedView:_progressView];
}

- (void)_documentController:(NSDocumentController *)documentController didCloseAll:(BOOL)didCloseAll contextInfo:(void *)contextInfo;
{
    // Edited document still open.  Leave our 'Update and Relaunch' view up; the user might save and decide to install the update in a little bit.
    if (!didCloseAll)
        return;
    
    [self _setDisplayedView:_plainStatusView];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // The code below will eventually call the normal NSApp termination logic (which the app can use to close files and such).
    OSUInstaller *installer = [[OSUInstaller alloc] initWithPackagePath:_destinationFile];
    installer.archiveExistingVersion = [defaults boolForKey:UpgradeKeepsExistingVersionPreferenceKey];
    installer.deletePackageOnSuccess = ![defaults boolForKey:UpgradeKeepsPackagePreferenceKey];
    [installer setInstalledVersion:[[[NSBundle mainBundle] bundlePath] stringByExpandingTildeInPath]];
    if (_installationDirectory)
        installer.installationDirectory = _installationDirectory;
    [installer setDelegate:self];
    
    [installer run];
    [installer release];
}

- (IBAction)installAndRelaunch:(id)sender;
{
    // Close all the document windows, allowing the user to cancel.
    [[NSDocumentController sharedDocumentController] closeAllDocumentsWithDelegate:self didCloseAllSelector:@selector(_documentController:didCloseAll:contextInfo:) contextInfo:NULL];
}

- (IBAction)revealDownloadInFinder:(id)sender;
{
    [[NSWorkspace sharedWorkspace] selectFile:_destinationFile inFileViewerRootedAtPath:nil];
    [self close];
}

- (void)setStatus:(NSString *)newStatus
{
    if (OFISEQUAL(newStatus, _status))
        return;
    
    [self willChangeValueForKey:OSUDownloadControllerStatusKey];
    [newStatus retain];
    [_status release];
    _status = newStatus;
    [self didChangeValueForKey:OSUDownloadControllerStatusKey];

    [[self window] displayIfNeeded];
}

- (void)_didChooseDirectory:(NSSavePanel *)sheet returnCode:(NSInteger)code contextInfo:(void *)contextInfo;
{
    if (code == NSFileHandlingPanelOKButton) {
        // Success!
        [self setInstallationDirectory:[sheet filename]];
    }
}

- (IBAction)chooseDirectory:(id)sender;
{
    // TODO: This is copy&pasted from OSUInstaller. Consolidate?

    // Set up the save panel for selecting an install location.
    NSOpenPanel *chooseInstallLocation = [NSOpenPanel openPanel];
    NSArray *allowedTypes = [NSArray arrayWithObject:(id)kUTTypeApplicationBundle];
    [chooseInstallLocation setAllowedFileTypes:allowedTypes];
    [chooseInstallLocation setAllowsOtherFileTypes:NO];
    [chooseInstallLocation setCanCreateDirectories:YES];
    [chooseInstallLocation setCanChooseDirectories:YES];
    [chooseInstallLocation setCanChooseFiles:NO];
    [chooseInstallLocation setResolvesAliases:YES];
    [chooseInstallLocation setAllowsMultipleSelection:NO];    
    
    NSString *chosenDirectory;
    
    chosenDirectory = [OSUInstaller suggestAnotherInstallationDirectory:[self installationDirectory] trySelf:YES];
    
    // If we couldn't find any writable directories, we're kind of screwed, but go ahead and pop up the panel in case the user can navigate somewhere
    
    [chooseInstallLocation beginSheetForDirectory:chosenDirectory
                                             file:nil
                                            types:allowedTypes
                                   modalForWindow:[self window]
                                    modalDelegate:self didEndSelector:@selector(_didChooseDirectory:returnCode:contextInfo:)
                                      contextInfo:NULL];
}

#pragma mark -
#pragma mark KVC/KVO

@synthesize installationDirectoryNote = _installationDirectoryNote;

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key;
{
    if ([key isEqualToString:OSUDownloadControllerSizeKnownKey])
	return [NSSet setWithObject:OSUDownloadControllerTotalSizeKey];
    return [super keyPathsForValuesAffectingValueForKey:key];
}

- (BOOL)sizeKnown;
{
    return _totalSize != 0ULL;
}

- (void)setInstallationDirectory:(NSString *)newDirectory
{
    if (OFISEQUAL(_installationDirectory, newDirectory))
        return;
    
    [self willChangeValueForKey:OSUDownloadControllerInstallationDirectoryKey];
    [_installationDirectory release];
    _installationDirectory = [newDirectory copy];
    [self didChangeValueForKey:OSUDownloadControllerInstallationDirectoryKey];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *noteTemplate = nil;
    
    if (newDirectory && ![newDirectory isEqualToString:[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent]]) {
        if (!noteTemplate) {
            NSString *homeDir = [NSHomeDirectory() stringByExpandingTildeInPath];
            if ([fileManager path:homeDir isAncestorOfPath:newDirectory relativePath:NULL]) {
                noteTemplate = NSLocalizedStringFromTableInBundle(@"The update will be installed in your @ folder.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"Install dialog message - small note indicating that app will be installed in a user directory - @ is replaced with name of directory, eg Applications");
            }
        }
        
        if (!noteTemplate) {
            noteTemplate = NSLocalizedStringFromTableInBundle(@"The update will be installed in the @ folder.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"Install dialog message - small note indicating that app will be installed in a system or network directory - @ is replaced with name of directory, eg Applications");
        }
    }
    
    if (noteTemplate) {
        CGFloat fontSize = [NSFont smallSystemFontSize];
        
        NSString *displayName = [fileManager displayNameAtPath:newDirectory];
        if (!displayName) {
            displayName = [newDirectory lastPathComponent];
        }
        NSMutableAttributedString *infix = [[NSMutableAttributedString alloc] initWithString:displayName];
        
        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:newDirectory];
        if (icon && [icon isValid]) {
            icon = [icon copy];
            [icon setScalesWhenResized:YES];
            [icon setSize:(NSSize){fontSize, fontSize}];
            [infix replaceCharactersInRange:(NSRange){0, 0} withString:[NSString stringWithCharacter:0x00A0]]; // non-breaking space
            [infix replaceCharactersInRange:(NSRange){0, 0} withAttributedString:[NSAttributedString attributedStringWithImage:icon]];
            [icon release];
        }
        
        [infix addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:fontSize] range:(NSRange){0, [infix length]}];
        
        NSMutableAttributedString *message = [[NSMutableAttributedString alloc] initWithString:noteTemplate
                                                                                  attributes:[NSDictionary dictionaryWithObject:[NSFont messageFontOfSize:fontSize] forKey:NSFontAttributeName]];
        [message replaceCharactersInRange:[noteTemplate rangeOfString:@"@"] withAttributedString:infix];
        
        [infix release];
        
        [self willChangeValueForKey:OSUDownloadControllerInstallationDirectoryNoteKey];
        [_installationDirectoryNote release];
        _installationDirectoryNote = message; // Consumes refcount from alloc+init
        [self didChangeValueForKey:OSUDownloadControllerInstallationDirectoryNoteKey];
    } else {
        if (_installationDirectoryNote != nil) {
            [self willChangeValueForKey:OSUDownloadControllerInstallationDirectoryNoteKey];
            [_installationDirectoryNote release];
            _installationDirectoryNote = nil;
            [self didChangeValueForKey:OSUDownloadControllerInstallationDirectoryNoteKey];
        }
    }
    
    if (_displayingInstallView)
        [self queueSelectorOnce:@selector(_setInstallViews)];
}

#pragma mark -
#pragma mark NSURLDownload delegate

- (void)downloadDidBegin:(NSURLDownload *)download;
{
    DEBUG_DOWNLOAD(@"did begin %@", download);
}

- (NSURLRequest *)download:(NSURLDownload *)download willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse;
{
    DEBUG_DOWNLOAD(@"will send request %@ for %@", request, download);
    return request;
}

- (void)download:(NSURLDownload *)download didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    DEBUG_DOWNLOAD(@"didReceiveAuthenticationChallenge %@", challenge);
    
    DEBUG_DOWNLOAD(@"protectionSpace = %@", [challenge protectionSpace]);
    DEBUG_DOWNLOAD(@"  realm = %@", [[challenge protectionSpace] realm]);
    DEBUG_DOWNLOAD(@"  host = %@", [[challenge protectionSpace] host]);
    DEBUG_DOWNLOAD(@"  port = %d", [[challenge protectionSpace] port]);
    DEBUG_DOWNLOAD(@"  isProxy = %d", [[challenge protectionSpace] isProxy]);
    DEBUG_DOWNLOAD(@"  proxyType = %@", [[challenge protectionSpace] proxyType]);
    DEBUG_DOWNLOAD(@"  protocol = %@", [[challenge protectionSpace] protocol]);
    DEBUG_DOWNLOAD(@"  authenticationMethod = %@", [[challenge protectionSpace] authenticationMethod]);
    DEBUG_DOWNLOAD(@"  receivesCredentialSecurely = %d", [[challenge protectionSpace] receivesCredentialSecurely]);
    
    DEBUG_DOWNLOAD(@"previousFailureCount = %d", [challenge previousFailureCount]);
    NSURLCredential *proposed = [challenge proposedCredential];
    DEBUG_DOWNLOAD(@"proposed = %@", proposed);
    
    [_challenge autorelease];
    _challenge = [challenge retain];

    if ([challenge previousFailureCount] == 0 && (proposed != nil) && ![NSString isEmptyString:[proposed user]] && ![NSString isEmptyString:[proposed password]]) {
        // Try the proposed credentials, if any, the first time around.  I've gotten a non-nil proposal with a null user name on 10.4 before.
        [[_challenge sender] useCredential:proposed forAuthenticationChallenge:_challenge];
        return;
    }
    
    // Clear our status to stop the animation in the view.  NSProgressIndicator hates getting removed from the view while it is animating, yielding exceptions in the heartbeat thread.
    [self setValue:nil forKey:OSUDownloadControllerStatusKey];
    [self _setDisplayedView:_credentialsView];
    [self showWindow:nil];
    [NSApp requestUserAttention:NSInformationalRequest]; // Let the user know they need to interact with us (else the server will timeout waiting for authentication).
}

- (void)download:(NSURLDownload *)download didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    DEBUG_DOWNLOAD(@"didCancelAuthenticationChallenge %@", challenge);
}

- (void)download:(NSURLDownload *)download didReceiveResponse:(NSURLResponse *)response;
{
    DEBUG_DOWNLOAD(@"didReceiveResponse %@", response);
    DEBUG_DOWNLOAD(@"  URL %@", [response URL]);
    DEBUG_DOWNLOAD(@"  MIMEType %@", [response MIMEType]);
    DEBUG_DOWNLOAD(@"  expectedContentLength %qd", [response expectedContentLength]);
    DEBUG_DOWNLOAD(@"  textEncodingName %@", [response textEncodingName]);
    DEBUG_DOWNLOAD(@"  suggestedFilename %@", [response suggestedFilename]);
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        DEBUG_DOWNLOAD(@"  statusCode %d", [(NSHTTPURLResponse *)response statusCode]);
        DEBUG_DOWNLOAD(@"  allHeaderFields %@", [(NSHTTPURLResponse *)response allHeaderFields]);
    }

    [self setValue:[NSNumber numberWithUnsignedLongLong:[response expectedContentLength]] forKey:OSUDownloadControllerTotalSizeKey];
    [self _setDisplayedView:_progressView];
}

- (void)download:(NSURLDownload *)download willResumeWithResponse:(NSURLResponse *)response fromByte:(long long)startingByte;
{
    DEBUG_DOWNLOAD(@"willResumeWithResponse %@ fromByte %d", response, startingByte);
}

- (void)download:(NSURLDownload *)download didReceiveDataOfLength:(NSUInteger)length;
{
    off_t newBytesDownloaded = _currentBytesDownloaded + length;
    [self setValue:[NSNumber numberWithUnsignedLongLong:newBytesDownloaded] forKey:OSUDownloadControllerCurrentBytesDownloadedKey];
}

- (BOOL)download:(NSURLDownload *)download shouldDecodeSourceDataOfMIMEType:(NSString *)encodingType;
{
    DEBUG_DOWNLOAD(@"shouldDecodeSourceDataOfMIMEType %@", encodingType);
    return YES;
}

- (void)download:(NSURLDownload *)download decideDestinationWithSuggestedFilename:(NSString *)filename;
{
    DEBUG_DOWNLOAD(@"decideDestinationWithSuggestedFilename %@", filename);
    
    NSFileManager *manager = [NSFileManager defaultManager];
    
    // Save disk images to the user's downloads folder.
    NSString *folder = nil;
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES /* expand tilde */);
    if ([paths count] > 0) {
        folder = [paths objectAtIndex:0];
        if (folder && ![manager directoryExistsAtPath:folder]) {
            NSError *error = nil;
            if (![manager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error]) {
#ifdef DEBUG		
                NSLog(@"Unable to create download directory at specified location '%@' -- %@", folder, error);
#endif		    
                folder = nil;
            }
        }
    }
    
    if (!folder) {
        folder = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES/*expandTilde*/) lastObject];
        if ([NSString isEmptyString:folder]) {
            folder = [NSSearchPathForDirectoriesInDomains(NSUserDirectory, NSUserDomainMask, YES/*expandTilde*/) lastObject];
            if ([NSString isEmptyString:folder]) {
                // Terrible news everyone!
#ifdef DEBUG		
                NSLog(@"Couldn't find a directory into which to download.");
#endif		
                [download cancel];
                return;
            }
        }
    }
    
    // On some people's machines, we'll end up with foo.tbz2.bz2 as the suggested name.  This is not good; it seems to come from having a 3rd party utility instaled that handles bz2 files, registering a set of UTIs that convinces NSURLDownload to suggest the more accurate extension.  So, we ignore the suggestion and use the filename from the URL.
    
    NSString *originalFileName = [[_packageURL path] lastPathComponent];
    OBASSERT([[OSUInstaller supportedPackageFormats] containsObject:[originalFileName pathExtension]]);
    
    _suggestedDestinationFile = [[folder stringByAppendingPathComponent:originalFileName] copy];
    
    DEBUG_DOWNLOAD(@"  destination: %@", _suggestedDestinationFile);
    [download setDestination:_suggestedDestinationFile allowOverwrite:YES];
}

- (void)download:(NSURLDownload *)download didCreateDestination:(NSString *)path;
{
    DEBUG_DOWNLOAD(@"didCreateDestination %@", path);
    
    [_destinationFile autorelease];
    _destinationFile = [path copy];
    
    // Quarantine the file. Later, after we verify its checksum, we can remove the quarantine.
    NSError *qError = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm quarantinePropertiesForItemAtPath:path error:&qError] != nil) {
        // It already has a quarantine (presumably we're running with LSFileQuarantineEnabled in our Info.plist)
        // And apparently it's not possible to change the paramneters of an existing quarantine event
        // So just assume that NSURLDownload did something that was good enough
    } else {
        if ( !([[qError domain] isEqualToString:NSOSStatusErrorDomain] && [qError code] == unimpErr) ) {
            
            NSMutableDictionary *qua = [NSMutableDictionary dictionary];
            [qua setObject:(id)kLSQuarantineTypeOtherDownload forKey:(id)kLSQuarantineTypeKey];
            [qua setObject:[[download request] URL] forKey:(id)kLSQuarantineDataURLKey];
            NSString *fromWhere = [_item sourceLocation];
            if (fromWhere) {
                NSURL *parsed = [NSURL URLWithString:fromWhere];
                if (parsed)
                    [qua setObject:parsed forKey:(id)kLSQuarantineOriginURLKey];
            }
            
            [fm setQuarantineProperties:qua forItemAtPath:path error:NULL];
        }
    }
}

- (void)downloadDidFinish:(NSURLDownload *)download;
{
    DEBUG_DOWNLOAD(@"downloadDidFinish %@", download);
    _didFinishOrFail = YES;
    
    [self setValue:NSLocalizedStringFromTableInBundle(@"Verifying file\\U2026", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"Download status") forKey:OSUDownloadControllerStatusKey];
    NSString *caution = [_item verifyFile:_destinationFile];
    if (![NSString isEmptyString:caution]) {
        [_installViewCautionText setStringValue:caution];
        _showCautionText = YES;
    }
    
    [self setValue:NSLocalizedStringFromTableInBundle(@"Ready to Install", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"Download status - Done downloading, about to prompt the user to let us reinstall and restart the app") forKey:OSUDownloadControllerStatusKey];
    
    if (![NSApp isActive])
        [NSApp requestUserAttention:NSInformationalRequest];
    else
        [self showWindow:nil];
    
    [self _setInstallViews];
}

- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error;
{
    DEBUG_DOWNLOAD(@"didFailWithError %@", error);
    _didFinishOrFail = YES;
    
    BOOL suggestLocalFileProblem = NO;
    BOOL suggestTransitoryNetworkProblem = NO;
    BOOL shouldDisplayUnderlyingError = YES;
    NSInteger code = [error code];
    
    // Try to specialize the error text based on what happened.
    
    // NB: Apple cleverly returns NSURL error codes in kCFErrorDomainCFNetwork.
    if ([[error domain] isEqualToString:NSURLErrorDomain] || [[error domain] isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) {
        if (code == NSURLErrorCancelled || code == NSURLErrorUserCancelledAuthentication) {
            // Don't display errors thown due to the user cancelling the authentication.
            return;
        }
        
        if (code <= NSURLErrorCannotCreateFile && code >= (NSURLErrorCannotCreateFile - 1000)) {
            // This seems to be the range set aside for local-filesystem-related problems.
            suggestLocalFileProblem = YES;
        }
        
        if (code == NSURLErrorTimedOut ||
            code == NSURLErrorCannotConnectToHost ||
            code == NSURLErrorDNSLookupFailed ||
            code == NSURLErrorNotConnectedToInternet) {
            suggestTransitoryNetworkProblem = YES;
        }
        
        // Suppress display of the less-helpful generic error messages
        if (code == NSURLErrorUnknown || code == NSURLErrorCannotLoadFromNetwork)
            shouldDisplayUnderlyingError = NO;
        
    } else if ([[error domain] isEqualToString:NSCocoaErrorDomain]) {
        
        if (code == NSUserCancelledError) {
            // Don't display errors due to user cancelling an operation.
            return;
        }
        
        if (code >= NSFileErrorMinimum && code <= NSFileErrorMaximum) {
            suggestLocalFileProblem = YES;
        }
        
    }
    
        
    NSString *file = _destinationFile ? _destinationFile : _suggestedDestinationFile;
    
    NSString *errorSuggestion;
    
    if (file)
        errorSuggestion = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Unable to download %@ to %@.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error message - unable to download URL to LOCALFILENAME - will often be followed by more detailed explanation"), _packageURL, file];
    else
        errorSuggestion = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Unable to download %@.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error message - unable to download URL (but no LOCALFILENAME was chosen yet) - will often be followed by more detailed explanation"), _packageURL];

    if (suggestTransitoryNetworkProblem)
        errorSuggestion = [NSString stringWithStrings:errorSuggestion, @"\n\n",
                           NSLocalizedStringFromTableInBundle(@"This may be a temporary network problem.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error message - unable to download URL - extra text if it looks like a transitory network problem"), nil];
    
    if (suggestLocalFileProblem)
        errorSuggestion = [NSString stringWithStrings:errorSuggestion, @"\n\n",
                           NSLocalizedStringFromTableInBundle(@"Please check the permissions and space available in your downloads folder.", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error message - unable to download URL - extra text if it looks like a problem with the local filesystem"), nil];

    if (shouldDisplayUnderlyingError) {
        NSString *underly = [error localizedDescription];
        if (![NSString isEmptyString:underly])
            errorSuggestion = [NSString stringWithFormat:@"%@ (%@)", errorSuggestion, underly];
    }
    
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                  NSLocalizedStringFromTableInBundle(@"Download failed", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"error title"), NSLocalizedDescriptionKey,
                                  errorSuggestion, NSLocalizedRecoverySuggestionErrorKey,
                                  error, NSUnderlyingErrorKey,
                                  nil];
    error = [NSError errorWithDomain:OMNI_BUNDLE_IDENTIFIER code:OSUDownloadFailed userInfo:userInfo];
    
    error = [OFMultipleOptionErrorRecovery errorRecoveryErrorWithError:error object:nil options:[OSUSendFeedbackErrorRecovery class], [OFCancelErrorRecovery class], nil];
    if (![[self window] presentError:error])
        [self close]; // Didn't recover
}

- (NSString *)installationDirectory
{
    return _installationDirectory;
}

@end

@implementation OSUDownloadController (Private)

- (void)_setInstallViews;
{
    NSMutableArray *installViews = [NSMutableArray array];
    [installViews addObject:_installBasicView];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:UpgradeShowsOptionsPreferenceKey])
        [installViews addObject:_installOptionsView];
    else if (_installationDirectoryNote != nil)
        [installViews addObject:_installOptionsNoteView];
    if (_showCautionText) {
        [installViews addObject:_installWarningView];
        /* Resize the warning text, if it's tall, and resize its containing view as well. Unfortunately, just resizing the containing view and telling it to automatically resize its subviews doesn't do the right thing here, so we do the bookkeeping ourselves. */
        NSSize textSize = [_installViewCautionText desiredFrameSize:NSViewHeightSizable];
        NSRect textFrame = [_installViewCautionText frame];
        if (textSize.height <= originalWarningTextHeight) {
            [_installWarningView setFrameSize:originalWarningViewSize];
            textFrame.size.height = originalWarningTextHeight;
        } else {
            [_installWarningView setFrameSize:(NSSize){
                .width = originalWarningViewSize.width,
                .height = ceilf(originalWarningViewSize.height + textSize.height - originalWarningTextHeight)
            }];
            textFrame.size.height = textSize.height;
        }
        textFrame.origin.y = ceilf(NSMaxY([_installWarningView bounds]) - warningTextTopMargin - textFrame.size.height);
        [_installViewCautionText setFrame:textFrame];
        [_installViewCautionText setNeedsDisplay:YES];
        [_installWarningView setNeedsDisplay:YES];
    }
    [installViews addObject:_installButtonsView];
    
    _displayingInstallView = YES;
    [self setContentViews:installViews];
}

- (void)_setDisplayedView:(NSView *)aView;
{
    _displayingInstallView = NO;
    [self setContentViews:[NSArray arrayWithObject:aView]];
}

- (void)setContentViews:(NSArray *)newContent;
{
    NSWindow *window = [self window];
    
    // Get a list of view animations to position all the new content in _bottomView
    // (and to hide the old content)
    NSSize desiredBottomViewFrameSize = originalBottomViewSize;
    NSMutableArray *animations = [_bottomView animationsToStackSubviews:newContent finalFrameSize:&desiredBottomViewFrameSize];
    
    // Compute the desired size of the window frame.
    // By virtue of the fact that our bottom view is flipped, resizable and the various contents are set to be top-aligned, this is the only resizing we need.
    
    CGFloat desiredWindowContentWidth = originalWindowSize.width + desiredBottomViewFrameSize.width - originalBottomViewSize.width;
    CGFloat desiredWindowContentHeight = originalWindowSize.height + desiredBottomViewFrameSize.height - originalBottomViewSize.height;
    NSRect oldFrame = [window frame];
    NSRect windowFrame = [window contentRectForFrameRect:oldFrame];
    CGFloat scaleFactor = [window userSpaceScaleFactor];
    windowFrame.size.width = desiredWindowContentWidth * scaleFactor;
    windowFrame.size.height = desiredWindowContentHeight * scaleFactor;
    windowFrame = [window frameRectForContentRect:windowFrame];
    
    // It looks nicest if we keep the window's title bar in approximately the same position when resizing.
    // NSWindow screen coordinates are in a Y-increases-upwards orientation.
    windowFrame.origin.y += ( NSMaxY(oldFrame) - NSMaxY(windowFrame) );
    // If moving horizontally, let's see if keeping a point 1/3 from the left looks good.
    windowFrame.origin.x = oldFrame.origin.x + (oldFrame.size.width - windowFrame.size.width)/3;
    
    windowFrame = NSIntegralRect(windowFrame);
    NSScreen *windowScreen = [window screen];
    if (windowScreen) {
        windowFrame = OFConstrainRect(windowFrame, [windowScreen visibleFrame]);
    }
    
    if (!NSEqualRects(oldFrame, windowFrame)) {
        NSString *keys[3] = { NSViewAnimationTargetKey, NSViewAnimationStartFrameKey, NSViewAnimationEndFrameKey };
        id values[3] = { window, [NSValue valueWithRect:oldFrame], [NSValue valueWithRect:windowFrame] };
        [animations addObject:[NSDictionary dictionaryWithObjects:values forKeys:keys count:3]];
    }
    
    // Animate if there was anything to do.
    if ([animations count]) {
        NSViewAnimation *animation = [[[NSViewAnimation alloc] initWithViewAnimations:animations] autorelease];
        [animation setDuration:0.1];
        [animation setAnimationBlockingMode:NSAnimationBlocking];
        [animation startAnimation];
    }
    
    // Set up the key view loop.
    // If there are no animations, assume we don't need to make any changes to the key view loop.
    if ([animations count]) {
        NSUInteger viewCount = [newContent count];
        
        // Find the view that followed all the views inside _bottomView, so we can attach it to the end of the new sequence of views
        NSView *keyViewLoopAnchor = [[_bottomView lastChildKeyView] nextKeyView];
        
        // Attach the beginning of the list of child views to the _bottomView
        if (viewCount > 0)
            [_bottomView setNextKeyView:[newContent objectAtIndex:0]];
        else
            [_bottomView setNextKeyView:keyViewLoopAnchor];
        
        // Attach the last child key view of each view to the next view
        for(NSUInteger viewIndex = 0; viewIndex < viewCount; viewIndex ++) {
            NSView *aView = [newContent objectAtIndex:viewIndex];
            NSView *linkTail = [aView lastChildKeyView];
            if (viewIndex+1 < viewCount)
                [linkTail setNextKeyView:[newContent objectAtIndex:viewIndex+1]];
            else
                [linkTail setNextKeyView:keyViewLoopAnchor];
        }
    }
}

- (void)_cancel;
{
    OBPRECONDITION(CurrentDownloadController == self || CurrentDownloadController == nil);
    
    if (CurrentDownloadController == self)
        CurrentDownloadController = nil;
    
    [[_challenge sender] cancelAuthenticationChallenge:_challenge];
    [_challenge release];
    _challenge = nil;
    
    if (!_didFinishOrFail) {
        // NSURLDownload will delete the downloaded file if you -cancel it after a successful download!  So, only call -cancel if we didn't finish or fail.
        [_download cancel];
        
        // If we are explictly cancelling, delete the file
        if (![NSString isEmptyString:_destinationFile])
            [[NSFileManager defaultManager] removeItemAtPath:_destinationFile error:NULL];
    }
    
    [_download release];
    _download = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context;
{
    if (context == [OSUDownloadController class]) {
        if (_displayingInstallView) {
            [self queueSelectorOnce:@selector(_setInstallViews)];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end

