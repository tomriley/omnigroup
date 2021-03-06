// Copyright 2001-2009 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OSUPreferences.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>
#import <OmniAppKit/OmniAppKit.h>
#import <mach-o/arch.h>
#import <WebKit/WebKit.h>

#import "OSUController.h"
#import "OSUChecker.h"
#import "OSUItem.h"

RCS_ID("$Id$");

typedef enum { Daily, Weekly, Monthly } CheckFrequencyMark;

static OFPreference *automaticSoftwareUpdateCheckEnabled = nil;
static OFPreference *checkInterval = nil;
static OFPreference *includeHardwareDetails = nil;
static OFPreference *updatesToIgnore = nil;

@interface OSUPreferences (Private)
- (void)_systemConfigurationSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
@end


@implementation OSUPreferences

+ (void)initialize;
{
    OBINITIALIZE;
    automaticSoftwareUpdateCheckEnabled = [[OFPreference preferenceForKey:@"AutomaticSoftwareUpdateCheckEnabled"] retain];
    checkInterval = [[OFPreference preferenceForKey:@"OSUCheckInterval"] retain];
    includeHardwareDetails = [[OFPreference preferenceForKey:@"OSUIncludeHardwareDetails"] retain];
    updatesToIgnore = [[OFPreference preferenceForKey:@"OSUIgnoredUpdates"] retain];
}

+ (OFPreference *)automaticSoftwareUpdateCheckEnabled;
{
    return automaticSoftwareUpdateCheckEnabled;
}

+ (OFPreference *)checkInterval;
{
    return checkInterval;
}

+ (OFPreference *)includeHardwareDetails;
{
    return includeHardwareDetails;
}

+ (OFPreference *)ignoredUpdates;
{
    return updatesToIgnore;
}

+ (void)setItem:(OSUItem *)anItem isIgnored:(BOOL)shouldBeIgnored;
{
    NSString *itemRepr = [[anItem buildVersion] cleanVersionString];
    if (!itemRepr)
        return;
    itemRepr = [@"v" stringByAppendingString:itemRepr];
    
    OFPreference *currentlyIgnored = [self ignoredUpdates];
    NSMutableArray *ignorance = [[currentlyIgnored stringArrayValue] mutableCopy];
    
    if (shouldBeIgnored && ![ignorance containsObject:itemRepr]) {
        [ignorance addObject:itemRepr];
        [ignorance sortUsingSelector:@selector(compare:)];
        [currentlyIgnored setArrayValue:ignorance];
        [[NSUserDefaults standardUserDefaults] autoSynchronize];
    } else if (!shouldBeIgnored && [ignorance containsObject:itemRepr]) {
        [ignorance removeObject:itemRepr];
        [currentlyIgnored setArrayValue:ignorance];
        if (![currentlyIgnored hasNonDefaultValue])
            [currentlyIgnored restoreDefaultValue];
        [[NSUserDefaults standardUserDefaults] autoSynchronize];
    }
    
    [ignorance release];
}


+ (BOOL)itemIsIgnored:(OSUItem *)anItem;
{
    OFVersionNumber *itemRepr = [anItem buildVersion];
    if (!itemRepr)
        return NO;
    
    return [[[self ignoredUpdates] stringArrayValue] containsObject:[@"v" stringByAppendingString:[itemRepr cleanVersionString]]];
}

- (void)awakeFromNib;
{
    // Format the informational message in the window based on the original format string stored in the nib
    NSString *format = [infoTextField stringValue];
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *value = [NSString stringWithFormat:format, processName, processName];
    [infoTextField setStringValue:value];

    [super awakeFromNib];
}    

- (void)willBecomeCurrentPreferenceClient;
{
    if ([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask)
        [self queueSelector:@selector(checkNow:) withObject:nil];
}

- (void)updateUI;
{
    int checkFrequencyInDays, itemIndexToSelect;
    
    [enableButton setState:[automaticSoftwareUpdateCheckEnabled boolValue]];
    checkFrequencyInDays = [checkInterval integerValue] / 24;

    if (checkFrequencyInDays > 27)
        itemIndexToSelect = [frequencyPopup indexOfItemWithTag:Monthly];
    else if (checkFrequencyInDays > 6)
        itemIndexToSelect = [frequencyPopup indexOfItemWithTag:Weekly];
    else
        itemIndexToSelect = [frequencyPopup indexOfItemWithTag:Daily];
    [frequencyPopup selectItemAtIndex:itemIndexToSelect];

    [includeHardwareButton setState:[includeHardwareDetails boolValue]];
}

- (IBAction)setValueForSender:(id)sender;
{
    if (sender == enableButton) {
        [automaticSoftwareUpdateCheckEnabled setBoolValue:[enableButton state]];
    } else if (sender == frequencyPopup) {
        int checkFrequencyInHours;
        
        switch ([[sender selectedItem] tag]) {
            case Daily:
                checkFrequencyInHours = 24;
                break;
            default:
            case Weekly:
                checkFrequencyInHours = 24 * 7;
                break;
            case Monthly:
                checkFrequencyInHours = 24 * 28; // lunar months! or would some average days per month figure be better?
                break;
        }
        [checkInterval setIntegerValue:checkFrequencyInHours];
    } else if (sender == includeHardwareButton) {
        [includeHardwareDetails setBoolValue:[includeHardwareButton state]];
    }
}

// API

- (IBAction)checkNow:(id)sender;
{
    [OSUController checkSynchronouslyWithUIAttachedToWindow:[controlBox window]];
}

- (IBAction)showSystemConfigurationDetailsSheet:(id)sender;
{
    NSBundle *bundle = [NSBundle bundleForClass:[isa class]];
    NSString *path = [bundle pathForResource:@"HardwareDescription" ofType:@"html"];
    if (!path) {
#ifdef DEBUG    
        NSLog(@"Cannot find HardwareDescription.html");
#endif	
        return;
    }
    
    NSData *htmlData = [[NSData alloc] initWithContentsOfFile:path];
    if (!htmlData) {
#ifdef DEBUG    
        NSLog(@"Cannot load HardwareDescription.html");
#endif	
        return;
    }

    // We have to do the variable replacement on the string since the tables in the HTML will get replaced with attachment cells
    NSMutableString *htmlString = [[[NSMutableString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding] autorelease];
    [htmlData release];

    // Get the system configuration report
    OSUChecker *checker = [OSUChecker sharedUpdateChecker];
    NSDictionary *_report = [checker generateReport];
    if (!_report) {
#ifdef DEBUG    
        NSLog(@"Couldn't generate report");
#endif	
        return;
    }

    NSMutableDictionary *report = [[[_report objectForKey:@"info"] mutableCopy] autorelease];
    
    // Do variable replacement on the HTML text
    {
        unsigned int length = [htmlString length];
        NSRange keyRange = (NSRange){0,0};

        while (YES) {
            keyRange.location = [htmlString rangeOfString:@"${" options:0 range:(NSRange){keyRange.location, length - keyRange.location}].location;
            if (keyRange.location == NSNotFound)
                break;

            keyRange.location += 2;
            unsigned int end = [htmlString rangeOfString:@"}" options:0 range:(NSRange){keyRange.location, length - keyRange.location}].location;
            keyRange.length = end - keyRange.location;
            
            NSString *key = [htmlString substringWithRange:keyRange];

            OSUChecker *checker = [OSUChecker sharedUpdateChecker];
            
            NSString *replacement = [[[report objectForKey:key] retain] autorelease];
            [report removeObjectForKey:key];
            
	    if ([key isEqualToString:@"OSU_VER"]) {
		replacement = [[OSUChecker OSUVersionNumber] originalVersionString];
            } else if ([key isEqualToString:@"OSU_APP_ID"]) {
                replacement = [checker applicationIdentifier];
            } else if ([key isEqualToString:@"OSU_APP_VER"]) {
                replacement = [checker applicationEngineeringVersion];
            } else if ([key isEqualToString:@"OSU_TRACK"]) {
                replacement = [checker applicationTrack];
            } else if ([key isEqualToString:@"OSU_VISIBLE_TRACKS"]) {
                // No longer sending this, but don't want to mess up the localizations, so just returning the current track
                //replacement = [[OSUChecker visibleTracks] componentsJoinedByString:@", "];
                replacement = [checker applicationTrack];
            } else if ([key isEqualToString:@"APP"]) {
                replacement = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
	    } else if ([key isEqualToString:@"license-type"]) {
		// This should be in the *main* bundle
		replacement = [[NSBundle mainBundle] localizedStringForKey:replacement value:replacement table:@"OZLicenseType"];
	    } else if ([key isEqualToString:@"KeyColumnWidthPercentage"]) {
		// Allow localizers to adjust the % space between the key and value columns (since their keys might be wideer).
		replacement = NSLocalizedStringWithDefaultValue(@"KeyColumnWidthPercentage", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"20", @"Percentage of table to allocate for values");
	    } else if ([key isEqualToString:@"lang"]) {
		NSString *localizedName = OFLocalizedNameForISOLanguageCode(replacement);
		if (localizedName)
		    replacement = localizedName;
	    } else if ([key isEqualToString:@"LATITUDE"]) {
		NSString *loc = [report objectForKey:@"loc"];
		NSArray *elements = [loc componentsSeparatedByString:@","];
		if ([elements count] == 2)
		    replacement = [elements objectAtIndex:0];
	    } else if ([key isEqualToString:@"LONGITUDE"]) {
		NSString *loc = [report objectForKey:@"loc"];
		NSArray *elements = [loc componentsSeparatedByString:@","];
		if ([elements count] == 2)
		    replacement = [elements objectAtIndex:1];
	    } else if ([key isEqualToString:@"cpu"]) {
		NSArray *elements = [replacement componentsSeparatedByString:@","];
		if ([elements count] == 2) {
		    const NXArchInfo *archInfo = NXGetArchInfoFromCpuType([[elements objectAtIndex:0] intValue],
									  [[elements objectAtIndex:1] intValue]);
		    if (archInfo)
			replacement = [NSString stringWithCString:archInfo->description encoding:NSASCIIStringEncoding];
		}
	    } else if ([key isEqualToString:@"cpuhz"] || [key isEqualToString:@"bushz"]) {
                NSDecimalNumber *bytes = [NSDecimalNumber decimalNumberWithString:replacement];
                replacement = [NSString abbreviatedStringForHertz:[bytes unsignedLongLongValue]];
	    } else if ([key isEqualToString:@"mem"]) {
                if ([replacement isEqualToString:@"-2147483648"]) {
                    // See the check tool -- sysctl blow up here.
                    replacement = @">= 2GB";
                } else {
                    NSDecimalNumber *bytes = [NSDecimalNumber decimalNumberWithString:replacement];
                    replacement = [NSString abbreviatedStringForBytes:[bytes unsignedLongLongValue]];
                }
	    } else if ([key isEqualToString:@"qt_netspeed"]) {
		if ([replacement intValue] == INT_MAX)
		    replacement = NSLocalizedStringFromTableInBundle(@"Internet/LAN", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"network speed");
		else {
		    float kbps = [replacement floatValue] / 100.0f; // QT encodes this a 100x not 1000x... dunno why.
		    if (kbps >= 1000)
			replacement = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"%g Mbps", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"network speed format string for megabits/second"), kbps/1000.0f];
		    else 
			replacement = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"%g Kbps", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"network speed format string for kilobits/second"), kbps];
		}
	    } else if ([key isEqualToString:@"DISPLAYS"]) {
		NSMutableString *displays = [NSMutableString string];

		unsigned int displayIndex = 0;
		while (YES) {
		    NSString *displayKey = [NSString stringWithFormat:@"display%d", displayIndex];
		    NSString *displayInfo = [report objectForKey:displayKey];
		    if (!displayInfo)
			break;
		    if ([displays length])
			[displays appendString:@"<br>"];
		    [displays appendString:displayInfo];
                    if ([displays length])
                        [displays appendString:@"<br>"];
		    [report removeObjectForKey:displayKey];

                    NSString *quartzExtremeKey = [NSString stringWithFormat:@"qe%d", displayIndex];
                    NSString *quartzExtreme = [report objectForKey:quartzExtremeKey];
                    if ([@"1" isEqualToString:quartzExtreme])
                        [displays appendString:NSLocalizedStringFromTableInBundle(@"Quartz Extreme Enabled", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel value - shown if Quartz Extreme is enabled")];
                    else if ([@"0" isEqualToString:quartzExtreme])
                        [displays appendString:NSLocalizedStringFromTableInBundle(@"Quartz Extreme Disabled", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel value - shown if Quartz Extreme is not enabled")];
                    else {
                        OBASSERT(NO);
                    }
                    if ([displays length])
                        [displays appendString:@"<br>"];
                    [report removeObjectForKey:quartzExtremeKey];

		    displayIndex++;
		}
		replacement = displays;
	    } else if ([key isEqualToString:@"VIDEO"]) {
		NSMutableString *adaptors = [NSMutableString string];

		// We only record the name of the first adaptor for now
		NSString *adaptorName = [report objectForKey:@"adaptor0_name"];
		if (adaptorName) {
		    static BOOL firstTime = YES;
		    static NSBundle *displayNamesBundle = nil;
		    if (firstTime) {
			firstTime = NO;
			displayNamesBundle = [[NSBundle bundleWithPath:@"/System/Library/SystemProfiler/SPDisplaysReporter.spreporter"] retain];
		    }
		    
		    if (displayNamesBundle)
			adaptorName = [displayNamesBundle localizedStringForKey:adaptorName value:adaptorName table:@"Localizable"];
		    [adaptors appendFormat:@"%@", adaptorName];
		    [report removeObjectForKey:@"adaptor0_name"];
		}
		
		unsigned int adaptorIndex = 0;
		while (YES) {
		    NSString *pciKey   = [NSString stringWithFormat:@"accel%d_pci", adaptorIndex];
		    NSString *glKey    = [NSString stringWithFormat:@"accel%d_gl", adaptorIndex];
		    NSString *identKey = [NSString stringWithFormat:@"accel%d_id", adaptorIndex];
		    NSString *verKey   = [NSString stringWithFormat:@"accel%d_ver", adaptorIndex];
		    
		    NSString *pci, *gl, *ident, *ver;
		    pci   = [report objectForKey:pciKey];
		    gl    = [report objectForKey:glKey];
		    ident = [report objectForKey:identKey];
		    ver   = [report objectForKey:verKey];
		    
		    if (!pci && !gl && !ident && !ver)
			break;
		    
		    if ([adaptors length])
			[adaptors appendString:@"<br><br>"];
		    
		    [adaptors appendString:NSLocalizedStringFromTableInBundle(@"PCI ID", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - PCI bus ID of video card")];
		    [adaptors appendFormat:@": %@<br>", pci ?: @""];
		    [adaptors appendString:NSLocalizedStringFromTableInBundle(@"OpenGL Driver", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - name of the OpenGL driver")];
		    [adaptors appendFormat:@": %@<br>", gl ?: @""];
		    [adaptors appendString:NSLocalizedStringFromTableInBundle(@"Hardware Driver", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - name of video card driver")];
		    [adaptors appendFormat:@": %@<br>", ident ?: @""];
		    [adaptors appendString:NSLocalizedStringFromTableInBundle(@"Driver Version", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - version of video card driver")];
		    [adaptors appendFormat:@": %@", ver ?: @""];

		    [report removeObjectForKey:pciKey];
		    [report removeObjectForKey:glKey];
		    [report removeObjectForKey:identKey];
		    [report removeObjectForKey:verKey];
		    adaptorIndex++;
		}
		
		NSString *memString = [report objectForKey:@"accel_mem"];
		if (memString) {
		    [adaptors appendString:@"<br>"];
		    if (adaptorIndex == 1) {
			[adaptors appendString:NSLocalizedStringFromTableInBundle(@"Memory", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - amount of video memory installed")];
			[adaptors appendString:@": "];
		    } else
			[adaptors appendString:@"<br>"];
		    
		    NSArray *mems = [memString componentsSeparatedByString:@","];
		    unsigned int memIndex, memCount = [mems count];
		    for (memIndex = 0; memIndex < memCount; memIndex++) {
			if (memIndex)
			    [adaptors appendString:@", "];
			[adaptors appendString:[NSString abbreviatedStringForBytes:[[mems objectAtIndex:memIndex] intValue]]];
		    }
		    [report removeObjectForKey:@"accel_mem"];
		}


		replacement = adaptors;
            } else if ([key isEqualToString:@"OPENGL"]) {
                NSMutableString *glInfo = [NSMutableString string];

                unsigned int adaptorIndex = 0;
                while (YES) {
                    NSString *vendorKey     = [NSString stringWithFormat:@"gl_vendor%d", adaptorIndex];
                    NSString *rendererKey   = [NSString stringWithFormat:@"gl_renderer%d", adaptorIndex];
                    NSString *versionKey    = [NSString stringWithFormat:@"gl_version%d", adaptorIndex];
                    NSString *extensionsKey = [NSString stringWithFormat:@"gl_extensions%d", adaptorIndex];

                    NSString *vendor, *renderer, *version, *extensions;
                    vendor     = [report objectForKey:vendorKey];
                    renderer   = [report objectForKey:rendererKey];
                    version    = [report objectForKey:versionKey];
                    extensions = [report objectForKey:extensionsKey];

                    if (!vendor && !renderer && !version && !extensions)
                        break;

                    if ([glInfo length])
                        [glInfo appendString:@"<br><br>"];

		    [glInfo appendString:NSLocalizedStringFromTableInBundle(@"OpenGL Vendor", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string")];
                    [glInfo appendFormat:@": %@<br>", vendor ?: @""];
		    [glInfo appendString:NSLocalizedStringFromTableInBundle(@"OpenGL Renderer", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string")];
                    [glInfo appendFormat:@": %@<br>", renderer ?: @""];
		    [glInfo appendString:NSLocalizedStringFromTableInBundle(@"OpenGL Version", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string")];
                    [glInfo appendFormat:@": %@<br>", version ?: @""];
		    [glInfo appendString:NSLocalizedStringFromTableInBundle(@"OpenGL Extensions", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string")];
                    [glInfo appendFormat:@": %@<br>", extensions ?: @""];

                    [report removeObjectForKey:vendorKey];
                    [report removeObjectForKey:rendererKey];
                    [report removeObjectForKey:versionKey];
                    [report removeObjectForKey:extensionsKey];
                    adaptorIndex++;
                }

                replacement = glInfo;
            } else if ([key isEqualToString:@"RUNTIME"]) {
                NSMutableString *runtime = [NSMutableString string];
                NSString *hoursRunLabel = NSLocalizedStringFromTableInBundle(@"Hours Run", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - accumulated number of hours the program has been running");
                NSString *timesRunLabel = NSLocalizedStringFromTableInBundle(@"# of Launches", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - number of times the program has been launched");
                NSString *crashRunLabel = NSLocalizedStringFromTableInBundle(@"# of Crashes", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - number of times the program has crashed");
                
                [runtime appendString:@"<b>"];
                [runtime appendString:NSLocalizedStringFromTableInBundle(@"Current Version", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - for the section which lists run/launch/crash info for this particular version")];
                [runtime appendString:@"</b><br><table>"];
                [runtime appendFormat:@"<tr><td align=\"right\">%@</td><td>%.1f</td></tr>", hoursRunLabel, [[report objectForKey:@"runmin"] unsignedIntValue]/60.0];
                [report removeObjectForKey:@"runmin"];

                [runtime appendFormat:@"<tr><td align=\"right\">%@</td><td>%u</td></tr>", timesRunLabel, [[report objectForKey:@"nrun"] unsignedIntValue]];
                [report removeObjectForKey:@"nrun"];
                [runtime appendFormat:@"<tr><td align=\"right\">%@</td><td>%u</td></tr>", crashRunLabel, [[report objectForKey:@"ndie"] unsignedIntValue]];
                [report removeObjectForKey:@"ndie"];

                [runtime appendString:@"</table><br><table>"];

                [runtime appendString:@"<b>"];
                [runtime appendString:NSLocalizedStringFromTableInBundle(@"All Versions", @"OmniSoftwareUpdate", OMNI_BUNDLE, @"details panel string - for the section which lists run/launch/crash info for all versions")];
                [runtime appendString:@"</b>"];
                [runtime appendFormat:@"<tr><td align=\"right\">%@</td><td>%.1f</td></tr>", hoursRunLabel, [[report objectForKey:@"trunmin"] unsignedIntValue]/60.0];
                [report removeObjectForKey:@"trunmin"];
                [runtime appendFormat:@"<tr><td align=\"right\">%@</td><td>%u</td></tr>", timesRunLabel, [[report objectForKey:@"tnrun"] unsignedIntValue]];
                [report removeObjectForKey:@"tnrun"];
                [runtime appendFormat:@"<tr><td align=\"right\">%@</td><td>%u</td></tr>", crashRunLabel, [[report objectForKey:@"tndie"] unsignedIntValue]];
                [report removeObjectForKey:@"tndie"];
                
                [runtime appendString:@"</table>"];

                replacement = runtime;
            }
            
	    
            if (replacement) {
                // Expand the range to over the '${}'
                keyRange.location -= 2;
                keyRange.length   += 3;
                [htmlString replaceCharactersInRange:keyRange withString:replacement];
                keyRange.location += [replacement length];
		length = [htmlString length];
            }
        }

	[report removeObjectForKey:@"loc"]; // Gets handled by the synthetic LATITUDE and LONGITUDE keys
        if ([report count]) {
            NSLog(@"Unhandled keys: %@", report);
            OBASSERT(NO);
        }
    }
    
    [[systemConfigurationWebView mainFrame] loadHTMLString:htmlString baseURL:nil];
    [NSApp beginSheet:[systemConfigurationWebView window]
       modalForWindow:[[self controlBox] window]
        modalDelegate:self
       didEndSelector:@selector(_systemConfigurationSheetDidEnd:returnCode:contextInfo:)
          contextInfo:NULL];
}

- (IBAction)dismissSystemConfigurationDetailsSheet:(id)sender;
{
    [NSApp endSheet:[systemConfigurationWebView window]];
}

#pragma mark -
#pragma mark WebPolicyDelegate

- (void)webView:(WebView *)webView decidePolicyForNavigationAction:(NSDictionary *)actionInformation
	request:(NSURLRequest *)request
	  frame:(WebFrame *)frame
decisionListener:(id<WebPolicyDecisionListener>)listener;
{
    NSURL *url = [actionInformation objectForKey:WebActionOriginalURLKey];
    
    // about:blank is passed when loading the initial content
    if ([[url absoluteString] isEqualToString:@"about:blank"]) {
	[listener use];
	return;
    }
    
    // when a link is clicked reject it locally and open it in an external browser
    if ([[actionInformation objectForKey:WebActionNavigationTypeKey] intValue] == WebNavigationTypeLinkClicked) {
	[[NSWorkspace sharedWorkspace] openURL:url];
	[listener ignore];
	return;
    }

#ifdef DEBUG
    NSLog(@"action %@, request %@", actionInformation, request);
#endif
}

- (void)webView:(WebView *)webView unableToImplementPolicyWithError:(NSError *)error frame:(WebFrame *)frame;
{
#ifdef DEBUG
    NSLog(@"error %@", error);
#endif    
}

@end

@implementation OSUPreferences (Private)
- (void)_systemConfigurationSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
{
    [sheet orderOut:nil];
}
@end
