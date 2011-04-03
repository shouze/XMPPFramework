#import "iPhoneXMPPAppDelegate.h"
#import "RootViewController.h"
#import "SettingsViewController.h"

#import "XMPP.h"
#import "XMPPRosterCoreDataStorage.h"

#import "DDLog.h"
#import "DDTTYLogger.h"

#import <CFNetwork/CFNetwork.h>

// Log levels: off, error, warn, info, verbose
static const int ddLogLevel = LOG_LEVEL_VERBOSE;


@interface iPhoneXMPPAppDelegate()

- (void)setupStream;

- (void)goOnline;
- (void)goOffline;

@end

#pragma mark -
@implementation iPhoneXMPPAppDelegate

@synthesize xmppStream;
@synthesize xmppRoster;
@synthesize xmppRosterStorage;

@synthesize window;
@synthesize navigationController;
@synthesize settingsViewController;
@synthesize loginButton;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	// Configure logging framework
	
	[DDLog addLogger:[DDTTYLogger sharedInstance]];
  
  // Setup the view controllers
  
  [window setRootViewController:navigationController];
  [window makeKeyAndVisible];
  
  // Setup the XMPP stream
  
  [self setupStream];
  
  if (![self connect]) {
    [navigationController presentModalViewController:settingsViewController animated:YES];
  }
		
  return YES;
}

- (void)dealloc
{
	[xmppStream removeDelegate:self];
	[xmppRoster removeDelegate:self];
	
	[xmppStream disconnect];
	[xmppStream release];
	[xmppRoster release];
	
	[password release];
	
  [loginButton release];
  [settingsViewController release];
	[navigationController release];
	[window release];
	
	[super dealloc];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Private
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Configure the xmpp stream
- (void)setupStream
{
  // Initialize variables
	
	xmppStream = [[XMPPStream alloc] init];
	
	xmppRosterStorage = [[XMPPRosterCoreDataStorage alloc] init];
	xmppRoster = [[XMPPRoster alloc] initWithRosterStorage:xmppRosterStorage];
	
	// Configure modules
	
	[xmppRoster setAutoRoster:YES];
	
	// Activate xmpp modules
	
	[xmppRoster activate:xmppStream];
	
	// Add ourself as a delegate to anything we may be interested in
	
	[xmppStream addDelegate:self delegateQueue:dispatch_get_main_queue()];
  
	// Optional:
	// 
	// Replace me with the proper domain and port.
	// The example below is setup for a typical google talk account.
	// 
	// If you don't supply a hostName, then it will be automatically resolved using the JID (below).
	// For example, if you supply a JID like 'user@quack.com/rsrc'
	// then the xmpp framework will follow the xmpp specification, and do a SRV lookup for quack.com.
	// 
	// If you don't specify a hostPort, then the default (5222) will be used.
  //	[xmppStream setHostName:@"talk.google.com"];
  //	[xmppStream setHostPort:5222];		
  
  // You may need to alter these settings depending on the server you're connecting to
	allowSelfSignedCertificates = NO;
	allowSSLHostNameMismatch = NO;
}

// It's easy to create XML elments to send and to read received XML elements.
// You have the entire NSXMLElement and NSXMLNode API's.
// 
// In addition to this, the NSXMLElementAdditions class provides some very handy methods for working with XMPP.
// 
// On the iPhone, Apple chose not to include the full NSXML suite.
// No problem - we use the KissXML library as a drop in replacement.
// 
// For more information on working with XML elements, see the Wiki article:
// http://code.google.com/p/xmppframework/wiki/WorkingWithElements

- (void)goOnline
{
	NSXMLElement *presence = [NSXMLElement elementWithName:@"presence"];
	
	[[self xmppStream] sendElement:presence];
}

- (void)goOffline
{
	NSXMLElement *presence = [NSXMLElement elementWithName:@"presence"];
	[presence addAttributeWithName:@"type" stringValue:@"unavailable"];
	
	[[self xmppStream] sendElement:presence];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connect/disconnect
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)connect
{
  if (![xmppStream isDisconnected]) {
    return YES;
  }
  
  NSString *myJID = [[NSUserDefaults standardUserDefaults] stringForKey:kXMPPmyJID];
  NSString *myPassword = [[NSUserDefaults standardUserDefaults] stringForKey:kXMPPmyPassword];
  
  //
  // If you don't want to use the Settings view to set the JID, 
  // uncomment the section below to hard code a JID and password.
  //
  // Replace me with the proper JID and password:
  //	myJID = @"user@gmail.com/xmppframework";
  //	myPassword = @"";
  
  if (myJID == nil || myPassword == nil) {
    DDLogWarn(@"JID and password must be set before connecting!");
    
    return NO;
  }
  
  [xmppStream setMyJID:[XMPPJID jidWithString:myJID]];
  password = myPassword;
  
  NSError *error = nil;
  if (![xmppStream connect:&error])
  {
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Error connecting" 
                                                        message:@"See console for error details." 
                                                       delegate:nil 
                                              cancelButtonTitle:@"Ok" 
                                              otherButtonTitles:nil];
    [alertView show];
    [alertView release];
    
    DDLogError(@"Error connecting: %@", error);
    
    return NO;
  }
  
  return YES;
}

- (void)disconnect {
  [self goOffline];
  
  [xmppStream disconnect];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark XMPPStream Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)xmppStream:(XMPPStream *)sender willSecureWithSettings:(NSMutableDictionary *)settings
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
	
	if (allowSelfSignedCertificates)
	{
		[settings setObject:[NSNumber numberWithBool:YES] forKey:(NSString *)kCFStreamSSLAllowsAnyRoot];
	}
	
	if (allowSSLHostNameMismatch)
	{
		[settings setObject:[NSNull null] forKey:(NSString *)kCFStreamSSLPeerName];
	}
	else
	{
		// Google does things incorrectly (does not conform to RFC).
		// Because so many people ask questions about this (assume xmpp framework is broken),
		// I've explicitly added code that shows how other xmpp clients "do the right thing"
		// when connecting to a google server (gmail, or google apps for domains).
		
		NSString *expectedCertName = nil;
		
		NSString *serverDomain = xmppStream.hostName;
		NSString *virtualDomain = [xmppStream.myJID domain];
		
		if ([serverDomain isEqualToString:@"talk.google.com"])
		{
			if ([virtualDomain isEqualToString:@"gmail.com"])
			{
				expectedCertName = virtualDomain;
			}
			else
			{
				expectedCertName = serverDomain;
			}
		}
		else
		{
			expectedCertName = serverDomain;
		}
		
		if (expectedCertName)
		{
			[settings setObject:expectedCertName forKey:(NSString *)kCFStreamSSLPeerName];
		}
	}
}

- (void)xmppStreamDidSecure:(XMPPStream *)sender
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
}

- (void)xmppStreamDidConnect:(XMPPStream *)sender
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
	
	isOpen = YES;
	
	NSError *error = nil;
	
	if (![[self xmppStream] authenticateWithPassword:password error:&error])
	{
		DDLogError(@"Error authenticating: %@", error);
	}
}

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
	
	[self goOnline];
}

- (void)xmppStream:(XMPPStream *)sender didNotAuthenticate:(NSXMLElement *)error
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	DDLogVerbose(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, [iq elementID]);
	
	return NO;
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)message
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
}

- (void)xmppStream:(XMPPStream *)sender didReceivePresence:(XMPPPresence *)presence
{
	DDLogVerbose(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, [presence fromStr]);
}

- (void)xmppStream:(XMPPStream *)sender didReceiveError:(id)error
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
}

- (void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error
{
	DDLogVerbose(@"%@: %@", THIS_FILE, THIS_METHOD);
	
	if (!isOpen)
	{
		DDLogError(@"Unable to connect to server. Check xmppStream.hostName");
	}
}

@end