//
// Copyright © 2013 Daniel Farrelly
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// *	Redistributions of source code must retain the above copyright notice, this list
//		of conditions and the following disclaimer.
// *	Redistributions in binary form must reproduce the above copyright notice, this
//		list of conditions and the following disclaimer in the documentation and/or
//		other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
// IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
// INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
// OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "JSMFileDrone.h"

@interface JSMFileDrone ()

@property (strong, nonatomic) NSTimer *surveillanceTimer;

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL;

@end

@implementation JSMFileDrone

#pragma mark - Creating a FileDrone

+ (instancetype)defaultFileDrone {
	static JSMFileDrone *_sharedDocuments = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
        NSURL *documentsURL = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        _sharedDocuments = [JSMFileDrone fileDroneForDirectoryURL:documentsURL];
	});
	return _sharedDocuments;
}

+ (instancetype)fileDroneForDirectoryURL:(NSURL *)directoryURL {
    return [[JSMFileDrone alloc] initWithDirectoryURL:directoryURL];
}

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL {
    if( ( self = [super init] ) ) {
        self.directoryURL = directoryURL;
    }
    return self;
}

- (void)dealloc {
    [self stopSurveillance];
}

#pragma mark - Directory

- (void)setDirectoryURL:(NSURL *)directoryURL {
    // Check that this path exists
    BOOL isDirectory;
    if( ! [NSFileManager.defaultManager fileExistsAtPath:directoryURL.path isDirectory:&isDirectory] || ! isDirectory ) {
        NSString *reason = [NSString stringWithFormat:@"%@ is not a valid watchable directory. Please provide a NSURL representing a valid directory.", directoryURL.path];
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:reason userInfo:nil];
    }
    // If we're surveilling, stop for now
    BOOL isSurveilling = self.isSurveilling;
    if( isSurveilling ) {
        [self stopSurveillance];
    }
    // Set the directoryURL
    _directoryURL = directoryURL;
    // Start surveilling again
    if( isSurveilling ) {
        [self startSurveillance];
    }
}

#pragma mark - Manual surveillance

- (void)refresh {
    // Fetch an enumerator so we can go through the directory contents
    NSDirectoryEnumerator *dirEnumerator = [NSFileManager.defaultManager
                                            enumeratorAtURL:_directoryURL
                                            includingPropertiesForKeys:[NSArray arrayWithObjects:NSURLIsDirectoryKey, nil]
                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                            errorHandler:^BOOL(NSURL *url, NSError *error) {
                                                return YES;
                                            }];
    // We're going to fetch a list of files, and a list of new ones
    NSMutableArray *fileURLs = [NSMutableArray array];
    NSMutableArray *addedFileURLs = [NSMutableArray array];
    // Enumerate the dirEnumerator results, each value is stored in allURLs
    for( NSURL *url in dirEnumerator ) {
        // If it's a directory, we do nothing
        NSNumber *isDirectory;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if( [isDirectory boolValue] == YES ) {
            continue;
        }
        // Match against the file name regular expression
        if( _fileNameRegex != nil ) {
            NSString *fileName;
            [url getResourceValue:&fileName forKey:NSURLNameKey error:NULL];
            if( [_fileNameRegex numberOfMatchesInString:fileName options:0 range:NSMakeRange( 0, fileName.length )] <= 0 ) {
                continue;
            }
        }
        // Match against the type identifier regular expression
        if( _typeIdentifierRegex != nil ) {
            NSString *typeIdentifier;
            [url getResourceValue:&typeIdentifier forKey:NSURLTypeIdentifierKey error:NULL];
            if( [_typeIdentifierRegex numberOfMatchesInString:typeIdentifier options:0 range:NSMakeRange( 0, typeIdentifier.length )] <= 0 ) {
                continue;
            }
        }
        // Make a URL relative to the watched directory
        NSURL *relativeURL = url.URLByStandardizingPath;
        // Add to the fileURLs array
        [fileURLs addObject:relativeURL];
        // If the url isn't in our existing list, it goes in the addedFileURLs too
        if( ! [_fileURLs containsObject:relativeURL] ) {
            [addedFileURLs addObject:relativeURL];
        }
    }
    // Now we determine what files were removed
    NSArray *removedFileURLs = [NSArray array];
    if( ! [_fileURLs isEqualToArray:fileURLs] ) {
        NSMutableSet *oldSet = [NSMutableSet setWithArray:_fileURLs];
        NSMutableSet *newSet = [NSMutableSet setWithArray:fileURLs];
        [oldSet minusSet:newSet];
        removedFileURLs = [oldSet allObjects];
    }
    // Update the list of files
    if( ! [_fileURLs isEqualToArray:fileURLs.copy] ) {
        _fileURLs = fileURLs.copy;
    }
    // User info dictionary for notification
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    // Update the list of added files
    if( ! [_addedFileURLs isEqualToArray:addedFileURLs.copy] ) {
        // Update the list
        _addedFileURLs = addedFileURLs.copy;
        // We only send the notification if there are files to process
        if( _addedFileURLs.count > 0 ) {
            [userInfo setObject:_addedFileURLs forKey:kFileDroneNotificationAddedURLs];
        }
    }
    // Update the list of removed files
    if( ! [_removedFileURLs isEqualToArray:removedFileURLs] ) {
        // Update the list
        _removedFileURLs = removedFileURLs;
        // We only send the notification if there are files to process
        if( _removedFileURLs.count > 0 ) {
            [userInfo setObject:_removedFileURLs forKey:kFileDroneNotificationRemovedURLs];
        }
    }
    // If we have user info, post the notification
    if( self.isSurveilling && userInfo.count > 0 ) {
        [userInfo setObject:_directoryURL forKey:kFileDroneNotificationDirectoryURL];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"JSMFileDroneFilesChanged" object:self userInfo:userInfo.copy];
    }
}

#pragma mark - Automatic surveillance

- (BOOL)isSurveilling {
    return ( _surveillanceTimer != nil && [_surveillanceTimer isValid] );
}

- (void)resumeSurveillance {
    // We're already surveilling
    if( self.isSurveilling ) {
        return;
    }
    // Start surveilling
    _surveillanceTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),^{
        // Fire the timer immediately
        [_surveillanceTimer fire];
        // Add to a runloop for continued firing
        [[NSRunLoop currentRunLoop] addTimer:_surveillanceTimer forMode:NSDefaultRunLoopMode];
		// Log entry
        NSLog(@"FileDrone started watching %@",_directoryURL.path.lastPathComponent);
        // Start the run loop
        [[NSRunLoop currentRunLoop] run];
    });
}

- (void)startSurveillance {
    // We're already surveilling
    if( self.isSurveilling ) {
        return;
    }
    // Add notifications for starting and stopping when the app transitions to and from the background
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeSurveillance) name:@"UIApplicationWillEnterForegroundNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeSurveillance) name:@"UIApplicationDidBecomeActiveNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pauseSurveillance) name:@"UIApplicationWillResignActiveNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pauseSurveillance) name:@"UIApplicationDidEnterBackgroundNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stopSurveillance) name:@"UIApplicationWillTerminateNotification" object:nil];
    // Start surveilling
    [self resumeSurveillance];
}

- (void)pauseSurveillance {
    // We're not surveilling
    if( ! self.isSurveilling ) {
        return;
    }
    // Stop the current surveillance
    [_surveillanceTimer invalidate];
    _surveillanceTimer = nil;
    // Log entry
    NSLog(@"FileDrone stopped watching %@",_directoryURL.path.lastPathComponent);
}

- (void)stopSurveillance {
    // We're not surveilling
    if( ! self.isSurveilling ) {
        return;
    }
    // Remove notifications for starting and stopping when the app transitions to and from the background
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIApplicationWillEnterForegroundNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIApplicationDidBecomeActiveNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIApplicationWillResignActiveNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIApplicationDidEnterBackgroundNotification" object:nil];
    // Stop the current surveillance
    [self pauseSurveillance];
}

@end
