//
//  DemoAppDelegate.m
//  Grocery Sync
//
//  Copyright 2011-2014 Couchbase, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

// NOTE: This file contains "pragma mark" markers highlighting the Couchbase Lite
// operations. You can easily find these by pulling down the Xcode methods menu above.

#import "DemoAppDelegate.h"
#import "LoginViewController.h"
#import "RootViewController.h"

#import <Couchbaselite/CouchbaseLite.h> // NOTE: If this import fails, make sure you have copied
// (or symlinked) CouchbaseLite.framework into the "Frameworks" subdirectory, as per the README.

#import "OpenIDController.h"

// The name of the local database the app will create. This name is mostly arbitrary, but must not
// be changed after deploying your app, or users will lose their data!
// (Note that database names cannot contain uppercase letters.)
#define kDatabaseName @"grocery-sync"

// The remote database URL to sync with. This is preconfigured with a sample database we maintain.
// In your own apps you will of course want to set this to a database you run, on your own Sync
// Gateway instance.
#define kServerDbURL @"http://us-west.testfest.couchbasemobile.com:4984/grocery-sync/"

#define kUserLocalDocID @"user"

#define kLoggingEnabled NO

typedef void (^ReplicatorSetup)(CBLReplication *repl);

typedef void (^SessionAuthCompletion)(NSArray  * __nullable sessionCookies,
                                      NSString * __nullable username,
                                      NSError  * __nullable error);

@interface DemoAppDelegate () <LoginViewControllerDelegate>

@end

@implementation DemoAppDelegate {
    CBLReplication *_pull;
    CBLReplication *_push;
    LoginViewController *_loginViewController;
    NSError *_syncError;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    if (kLoggingEnabled)
        [self enableLogging];

    if (![self initializeDatabase])
        return NO;

    [LoginViewController application:application didFinishLaunchingWithOptions:launchOptions];
    _loginViewController = (LoginViewController *)self.window.rootViewController;
    _loginViewController.delegate = self;

    return YES;
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary *)options {
    return [LoginViewController application:app openURL:url options:options];
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    return [LoginViewController application:application
                                    openURL:url
                          sourceApplication:sourceApplication
                                 annotation:annotation];
}

#pragma mark - Database

- (BOOL)initializeDatabase {
    NSError *error;
    self.database = [[CBLManager sharedInstance] databaseNamed:kDatabaseName error:&error];
    if (!self.database) {
        [self showAlert: @"Couldn't open database" error: error fatal: YES];
        return NO;
    }
    return YES;
}

- (void)enableLogging {
    [CBLManager enableLogging:@"Sync"];
    [CBLManager enableLogging:@"SyncVerbose"];
}

#pragma mark - Replication

- (NSURL *)serverDbURL {
    return [NSURL URLWithString: kServerDbURL];
}

- (void)startPull:(ReplicatorSetup)setup {
    _pull = [self.database createPullReplication:[self serverDbURL]];
    _pull.continuous = YES;

    setup(_pull);

    // Observe replication progress changes, in both directions:
    NSNotificationCenter *nctr = [NSNotificationCenter defaultCenter];
    [nctr addObserver:self selector:@selector(replicationProgress:)
                 name:kCBLReplicationChangeNotification object:_pull];
    [_pull start];
}

- (void)startPush:(ReplicatorSetup)setup {
    _push = [self.database createPushReplication:[self serverDbURL]];
    _push.continuous = YES;
    
    setup(_push);
    
    // Observe replication progress changes, in both directions:
    NSNotificationCenter *nctr = [NSNotificationCenter defaultCenter];
    [nctr addObserver:self selector:@selector(replicationProgress:)
                 name:kCBLReplicationChangeNotification object:_push];
    [_push start];
}

- (void)stopReplication {
    NSNotificationCenter *nctr = [NSNotificationCenter defaultCenter];
    if (_pull) {
        [_pull stop];
        [_pull removeObserver:self forKeyPath:@"status"];
        [nctr removeObserver:self name:kCBLReplicationChangeNotification object:_pull];
        _pull = nil;
    }

    if (_push) {
        [_push stop];
        [nctr removeObserver:self name:kCBLReplicationChangeNotification object:_push];
        _push = nil;
    }
    
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

// Called in response to replication-change notifications. Updates the progress UI.
#pragma mark Observe sync progress
- (void)replicationProgress:(NSNotificationCenter *)n {
    if (_pull.status == kCBLReplicationActive || _push.status == kCBLReplicationActive)
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    else
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];

    // Check for any change in error status and display new errors:
    NSError* error = _pull.lastError ? _pull.lastError : _push.lastError;
    if (error != _syncError) {
        _syncError = error;
        if (error) {
            NSLog(@"Sync Error : %@", error);
            [self showAlert:@"Sync Error" error:error fatal:NO];
        }
    }
}

#pragma mark - Alert

// Display an error alert, without blocking.
// If 'fatal' is true, the app will quit when it's dismissed.
- (void)showAlert:(NSString*)message error:(NSError*)error fatal:(BOOL)fatal {
    if (error)
        message = [message stringByAppendingFormat: @"\n\n%@", error.localizedDescription];
    UIAlertView* alert = [[UIAlertView alloc] initWithTitle:(fatal ? @"Fatal Error" : @"Error")
                                                    message:message
                                                   delegate:(fatal ? self : nil)
                                          cancelButtonTitle:(fatal ? @"Quit" : @"Sorry")
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    exit(0);
}

#pragma mark - LoginViewControllerDelegate

- (void)didLogout:(LoginViewController*)controller {
    self.username = nil;
    [self stopReplication];
}

#pragma mark - LoginViewControllerDelegate : Auth Code Flow

- (void)didAuthCodeSignIn:(LoginViewController *)controller {
    [self stopReplication];
    [self startPull:^(CBLReplication *repl) {
        repl.authenticator =
            [CBLAuthenticator OpenIDConnectAuthenticator:[OpenIDController loginCallback]];
        [repl addObserver:self forKeyPath:@"status" options:0 context:nil];
    }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"status"]) {
        CBLReplication *pull = (CBLReplication *)object;
        NSString *username = [pull.authenticator username];
        if (!self.username && username && [self isReplicatorStarted:pull]) {
            [pull removeObserver:self forKeyPath:@"status"];
            if ([self loginWithUsername:username]) {
                if (pull == _pull) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self startPush:^(CBLReplication *repl) {
                            repl.authenticator = [CBLAuthenticator OpenIDConnectAuthenticator:
                                                  [OpenIDController loginCallback]];
                        }];
                        [self completeLogin];
                    });
                } else {
                    // When switching the user, the database and _pull replicator are
                    // reset so we need to restart the authenticating process again.
                    // The authenticating process from here should happen silently.
                    [self didAuthCodeSignIn:nil];
                }
            }
        }
    }
}

- (BOOL)isReplicatorStarted:(CBLReplication *)repl {
    return repl.status == kCBLReplicationIdle || repl.changesCount > 0;
}

#pragma mark - LoginViewControllerDelegate : Google Signin

- (void)didGoogleSignIn:(LoginViewController*)controller
            withIdToken:(NSString *)idToken
              withError:(NSError *)error {
    if (!error) {
        [self authenticate:[self serverDbURL] withIdToken:idToken
                completion:
         ^(NSArray *sessionCookies, NSString *username, NSError *error) {
             if (!error && username) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                     if ([self loginWithUsername:username withSessionCookies:sessionCookies])
                         [self completeLogin];
                 });
             } else
                 [self showAlert:@"Authentication Failed" error:error fatal:NO];
         }];
    } else
        [self showAlert:@"Google SignIn Failed" error:error fatal:NO];
}


#pragma mark - Create SGW Session with ID Token from Google Signin

- (void)authenticate:(NSURL *)remoteUrl
         withIdToken:(NSString *)idToken
          completion:(SessionAuthCompletion)completion {
    NSURL *sessionUrl = [remoteUrl URLByAppendingPathComponent:@"_session"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:sessionUrl];
    [request setHTTPMethod:@"POST"];
    
    NSString *authValue = [NSString stringWithFormat: @"Bearer %@", idToken];
    [request setValue:authValue forHTTPHeaderField:@"Authorization"];
    
    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {
         NSArray *cookies;
         NSString *username;
         if (!error) {
             NSHTTPURLResponse *httpRes = (NSHTTPURLResponse*)response;
             cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[httpRes allHeaderFields]
                                                              forURL:remoteUrl];
             NSDictionary *sessionData =
             [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingMutableContainers error:nil];
             username = sessionData[@"userCtx"][@"name"];
         }
         completion(cookies, username, error);
     }];
    [task resume];
}

- (BOOL)loginWithUsername:(NSString *)username withSessionCookies:(NSArray *)sessionCookies {
    if ([self loginWithUsername:username]) {
        [self startPull:^(CBLReplication *pull){
            for (NSHTTPCookie *cookie in sessionCookies) {
                [pull setCookieNamed:cookie.name
                           withValue:cookie.value
                                path:cookie.path
                      expirationDate:cookie.expiresDate
                              secure:cookie.isSecure];
            }
        }];
        
        [self startPush:^(CBLReplication *push){
            for (NSHTTPCookie *cookie in sessionCookies) {
                [push setCookieNamed:cookie.name
                           withValue:cookie.value
                                path:cookie.path
                      expirationDate:cookie.expiresDate
                              secure:cookie.isSecure];
            }
        }];
    }
    return YES;
}

#pragma mark - Login user to the app

- (BOOL)loginWithUsername:(NSString *)username {
    NSDictionary *user = [self.database existingLocalDocumentWithID:kUserLocalDocID];
    if (self.database && user && ![user[@"username"] isEqualToString:username]) {
        [self stopReplication];
        [self.database deleteDatabase:nil];
        self.database = nil;
    }
    
    NSError *error;
    if (!self.database) {
        if (![self initializeDatabase])
            return NO;
    }
    
    [self.database putLocalDocument:@{@"username":username} withID:kUserLocalDocID error:&error];
    self.username = username;
    
    return YES;
}

#pragma mark - Complete login : show the app

- (void)completeLogin {
    dispatch_async(dispatch_get_main_queue(), ^{
        LoginViewController *controller = (LoginViewController *)self.window.rootViewController;
        [controller start];
    });
}

@end
