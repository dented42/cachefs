//
//  CacheFS.m
//  cachefs
//
//  Created by Matias Eyzaguirre on 4/14/12.
//  Copyright (c) 2012 J. Willard Marriott Library. All rights reserved.
//

#import <sys/xattr.h>
#import <sys/stat.h>
#import <OSXFUSE/OSXFUSE.h>

#import "CacheFS.h"

// TODO: At some point convert everything to use NSURL instead of raw strings for paths?

#define BUNDLE_IDENTIFIER @"edu.utah.cachefs"

// Category on NSError to  simplify creating an NSError based on posix errno.
@interface NSError (POSIX)
+ (NSError *)errorWithPOSIXCode:(int)code;
@end
@implementation NSError (POSIX)
+ (NSError *)errorWithPOSIXCode:(int) code {
  return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}
@end

@interface CacheFS () {
  
  NSString *cacheDir;
  NSString *sourceDir;
  
  dispatch_once_t init_queues_once;
  dispatch_queue_t cachingQueue;
  dispatch_queue_t userDataQueue;
  
  /* This deserves some explanation. When a cached file is closed FUSE releases
   * it's user data object. But a cached file could be closed and reopened, at
   * which point we don't want it's contents to be recached because it's
   * already in the cache. Therefore this dictionary stores the user data of
   * released files that might be reopened. Because it sort of stores user data,
   * access to the releasedFiles dictionary MUST be serialized through the
   * userDataQueue.
   */
  NSMutableDictionary *releasedFiles;
}

-(NSString*)sourcePath:(NSString*)path;
-(NSString*)cachedPath:(NSString*)path;

/* If caching is completed for the desired file, then it will return the cached
 * path, otherwise it will return the original source path. Also, if for some
 * reason caching has not begun for the file in question, then this method will
 * attempt to start it.
 */
-(NSString*)properPathFor:(NSString*)path
             withUserData:(NSMutableDictionary*)userData;

-(id)objectForKey:(id)key inUserData:(NSMutableDictionary*)userData;
-(void)setObject:(id)object forKey:(id)key inUserData:(NSMutableDictionary*)userData;

-(void)cacheFileForPath:(NSString*)path userData:(NSMutableDictionary*)userData;
-(void)flushCacheForPath:(NSString*)path userData:(NSMutableDictionary*)userData;

@end


@implementation CacheFS

-(id)initWithPath:(NSString*)path {
  self = [super init];
  if (self) {
    // create our queues
    dispatch_once(&init_queues_once, ^{
      cachingQueue = dispatch_queue_create("com.cachefs.cachingQueue", NULL);
      dispatch_set_target_queue(cachingQueue,
                                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
      
      userDataQueue = dispatch_queue_create("com.cachefs.UserDataQueue", NULL);
      dispatch_set_target_queue(userDataQueue,
                                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
      NSLog(@"Queues Created");
    });
    releasedFiles = [[NSMutableDictionary alloc] init];
    
    // set the cache directory
    NSString *topCache = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    cacheDir = [[topCache stringByAppendingPathComponent:BUNDLE_IDENTIFIER] stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSLog(@"Cache directory is %@", cacheDir);
    sourceDir = path;
    NSLog(@"Source path is %@", sourceDir);
  }
  return self;
}

// TODO: Finish Implementation
-(void)cleanUp {
  dispatch_queue_t tmpQ; // we need a temp variable
  NSLog(@"Starting Cleanup");
  
  // cleanup caching queue
  tmpQ = cachingQueue;
  cachingQueue = nil;
  dispatch_sync(tmpQ, ^{
    [[NSFileManager defaultManager] removeItemAtPath:cacheDir error:nil];
  });
  dispatch_release(tmpQ);
  
  // cleanup user data queue
  tmpQ = userDataQueue;
  userDataQueue = nil;
  dispatch_sync(tmpQ, ^{});
  dispatch_release(tmpQ);
  
  NSLog(@"Cleanup Complete");
}

-(id)objectForKey:(id)key inUserData:(NSMutableDictionary*)userData {
  __block id resultObject;
  dispatch_sync(userDataQueue, ^{
    resultObject = [userData objectForKey:key];
  });
  return resultObject;
}

-(void)setObject:(id)object forKey:(id)key inUserData:(NSMutableDictionary*)userData {
  dispatch_sync(userDataQueue, ^{
    [userData setObject:object forKey:key];
  });
}

-(void)cacheFileForPath:(NSString*)path userData:(NSMutableDictionary*)userData {
  // see if we should cache
  dispatch_async(userDataQueue, ^{
    // start the cache if needed
    if (![[userData objectForKey:@"cacheBegun"] boolValue]) {
      // indicate that we have begun the caching
      [userData setObject:[NSNumber numberWithBool:YES] forKey:@"cacheBegun"];
      dispatch_async(cachingQueue, ^{
        // actually cache the data
        [[NSFileManager defaultManager] removeItemAtPath:[self cachedPath:path] error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:[[self cachedPath:path] stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSError *err = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:[self sourcePath:path]
                                                    toPath:[self cachedPath:path]
                                                     error:&err]) {
          // if successful then set the cacheComplete bit
          [self setObject:[NSNumber numberWithBool:YES]
                   forKey:@"cacheComplete"
               inUserData:userData];
          // and set the modification date
          NSDictionary *attribs = [[NSFileManager defaultManager] attributesOfItemAtPath:[self sourcePath:path]
                                                                                   error:nil];
          [self setObject:[attribs objectForKey:NSFileModificationDate]
                   forKey:@"modificationDate"
               inUserData:userData];
          NSLog(@"Cache Successful for %@", path);
        } else { // if it fails then clean up and reset the cachBegun bit
          [[NSFileManager defaultManager] removeItemAtPath:[self cachedPath:path]
                                                     error:nil];
          NSLog(@"Cache failed for %@, error: %@", path, err);
        }
      });
    }
  });
}

-(void)flushCacheForPath:(NSString*)path
                userData:(NSMutableDictionary *)userData {
  dispatch_async(userDataQueue, ^{
    NSDictionary *sourceAttribs = [[NSFileManager defaultManager] attributesOfItemAtPath:[self sourcePath:path]
                                                                                   error:nil];
    NSDictionary *cachedAttribs = [[NSFileManager defaultManager] attributesOfItemAtPath:[self cachedPath:path]
                                                                                   error:nil];
    NSDate *sourceModDate = [sourceAttribs objectForKey:NSFileModificationDate];
    NSDate *cachedModDate = [cachedAttribs objectForKey:NSFileModificationDate];
    
    if ([cachedModDate compare:sourceModDate] == NSOrderedDescending) {
      dispatch_async(cachingQueue, ^{
        [[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:[self sourcePath:path]]
                                           withItemAtURL:[NSURL fileURLWithPath:[self cachedPath:path]]
                                          backupItemName:nil
                                                 options:0
                                        resultingItemURL:nil
                                                   error:nil];
      });
    }
  });
}

// TODO: Polish Implementation
/* eventual proper detection of when to recache the file because the
 * modification date on the source is more recent, which will involve also
 * checking the modification date of the local copy and using that instead, and
 * possibly flushing the local changes to the source if that would cause better
 * performance
 */
-(NSString*)properPathFor:(NSString*)path
             withUserData:(NSMutableDictionary*)userData {
  __block NSString *resultPath;
  dispatch_sync(userDataQueue, ^{
    // check if data has begun
    BOOL hasStarted = [[userData objectForKey:@"cacheBegun"] boolValue];
    // if not then start it
    if (!hasStarted) {
      [self cacheFileForPath:path userData:userData];
      resultPath = [self sourcePath:path];
    } else if ([[userData objectForKey:@"cacheComplete"] boolValue]) {
      // check to see if it's complete
      resultPath = [self cachedPath:path];
    } else {
      // otherwise use the source path
      resultPath = [self sourcePath:path];
    }
  });
  return resultPath;
}

#pragma mark helpers

-(NSString*)sourcePath:(NSString*)path {
  return [sourceDir stringByAppendingPathComponent:path];
}

-(NSString*)cachedPath:(NSString *)path {
  
  return [cacheDir stringByAppendingPathComponent:path];
}

#pragma mark Directory Contents

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
  //  *error = [NSError errorWithPOSIXCode:ENOENT];
  //  return nil;
  NSString* actualPath = [self sourcePath:path];
  return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:actualPath
                                                             error:error];
}

#pragma mark Getting and Setting Attributes

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error {
  //  *error = [NSError errorWithPOSIXCode:ENOENT];
  //  return nil;
  NSString *actualPath = [self sourcePath:path];
  return [[NSFileManager defaultManager] attributesOfItemAtPath:actualPath
                                                          error:error];
}

- (NSDictionary *)attributesOfFileSystemForPath:(NSString *)path
                                          error:(NSError **)error {
  //  return [NSDictionary dictionary];  // Default file system attributes.
  NSString* actualPath = [self sourcePath:path];
  return [[NSFileManager defaultManager] attributesOfFileSystemForPath:actualPath
                                                                 error:error];
}

- (BOOL)setAttributes:(NSDictionary *)attributes 
         ofItemAtPath:(NSString *)path
             userData:(id)userData
                error:(NSError **)error {
  //  return YES;
  NSString *actualPath = [self sourcePath:path];
  return [[NSFileManager defaultManager] setAttributes:attributes
                                          ofItemAtPath:actualPath
                                                 error:error];
}

#pragma mark File Contents

// TODO: do the right thing with regards to mode (Especially appending)
- (BOOL)openFileAtPath:(NSString *)path 
                  mode:(int)mode
              userData:(id *)userData
                 error:(NSError **)error {
  
  // see if there is a source file with what we want
  BOOL canRead, canWrite, canUse;
  {
    canRead = [[NSFileManager defaultManager] isReadableFileAtPath:[self sourcePath:path]];
    canWrite = [[NSFileManager defaultManager] isWritableFileAtPath:[self sourcePath:path]];
    if ((mode & O_RDONLY) == O_RDONLY) // O_RDONLY is 0 on my system...
      canUse = canRead;
    else if ((mode & O_WRONLY) == O_WRONLY)
      canUse = canWrite;
    else if ((mode & O_RDWR) == O_RDWR)
      canUse = canRead & canWrite;
    else
      canUse = NO;
  }
  
  if (canUse) {
    // if the file isn't already open
    if (*userData == nil) {
      // check the releasedFiles dictionary
      *userData = [self objectForKey:path inUserData:releasedFiles];
      // otherwise we'll have to synthesize a new one
      if (*userData == nil) {
        *userData = [[NSMutableDictionary alloc] init];
        [*userData setObject:[NSNumber numberWithBool:NO] forKey:@"cacheComplete"];
        [*userData setObject:[NSNumber numberWithBool:NO] forKey:@"cacheBegun"];
        // used to determine if there have been any changes to the source file
        [*userData setObject:[NSDate distantPast] forKey:@"modificationDate"];
      }
    }
    
    [self cacheFileForPath:path userData:*userData];
    
    return YES;
  } else {
    *error = [NSError errorWithPOSIXCode:ENOENT];
    return NO;
  }
}

- (void)releaseFileAtPath:(NSString *)path userData:(id)userData {
  NSLog(@"Releasing %@", path);
  // not much to do really... just cache the user data for later
  [self setObject:userData forKey:path inUserData:releasedFiles];
  [self flushCacheForPath:path userData:userData];
}

- (int)readFileAtPath:(NSString *)path 
             userData:(id)userData
               buffer:(char *)buffer 
                 size:(size_t)size 
               offset:(off_t)offset
                error:(NSError **)error {
  NSString* actualPath = [self properPathFor:path withUserData:userData];
  
  // open the file
  NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:actualPath];
  [file seekToFileOffset:offset];
  
  // copy the data (could be done more efficiently if required)
  NSData * segment = [file readDataOfLength:size];
  memcpy(buffer, [segment bytes], [segment length]);
  
  return [segment length];
}

- (int)writeFileAtPath:(NSString *)path 
              userData:(id)userData
                buffer:(const char *)buffer
                  size:(size_t)size 
                offset:(off_t)offset
                 error:(NSError **)error {
  NSString *actualPath = [self properPathFor:path withUserData:userData];
  
  // open the file
  NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:actualPath];
  [file seekToFileOffset:offset];
  
  // write the data
  NSData *segment = [NSData dataWithBytesNoCopy:(void*)buffer
                                         length:size
                                   freeWhenDone:NO];
  [file writeData:segment];
  [file closeFile];
  return size;
}

// (Optional)
// TODO: Maybe Write Implementation
//- (BOOL)exchangeDataOfItemAtPath:(NSString *)path1
//                  withItemAtPath:(NSString *)path2
//                           error:(NSError **)error {
//  return YES;
//}

#pragma mark Creating an Item

- (BOOL)createDirectoryAtPath:(NSString *)path 
                   attributes:(NSDictionary *)attributes
                        error:(NSError **)error {
  return [[NSFileManager defaultManager] createDirectoryAtPath:[self sourcePath:path]
                                   withIntermediateDirectories:NO
                                                    attributes:attributes
                                                         error:error];
}

- (BOOL)createFileAtPath:(NSString *)path 
              attributes:(NSDictionary *)attributes
                userData:(id *)userData
                   error:(NSError **)error {
  
  *userData = [[NSMutableDictionary alloc] init];
  [*userData setObject:[NSNumber numberWithBool:NO] forKey:@"cacheComplete"];
  [*userData setObject:[NSNumber numberWithBool:NO] forKey:@"cacheBegun"];
  // used to determine if there have been any changes to the source file
  [*userData setObject:[NSDate distantPast] forKey:@"modificationDate"];
  
  BOOL result = [[NSFileManager defaultManager] createFileAtPath:[self sourcePath:path]
                                                        contents:[NSData data]
                                                      attributes:attributes];
  
  [self cacheFileForPath:path userData:*userData];
  
  return result;
}

#pragma mark Moving an Item

- (BOOL)moveItemAtPath:(NSString *)source 
                toPath:(NSString *)destination
                 error:(NSError **)error {
  BOOL succ = [[NSFileManager defaultManager] moveItemAtPath:[self sourcePath:source]
                                                      toPath:[self sourcePath:destination]
                                                       error:error];
  if (succ) {
    dispatch_async(cachingQueue, ^{
      // make sure source is clear
      [[NSFileManager defaultManager] removeItemAtPath:[self cachedPath:destination]
                                                 error:nil];
      // make the move
      [[NSFileManager defaultManager] moveItemAtPath:[self cachedPath:source]
                                              toPath:[self cachedPath:destination]
                                               error:nil];
    });
    return YES;
  } else
    return NO;
}

#pragma mark Removing an Item

- (BOOL)removeDirectoryAtPath:(NSString *)path error:(NSError **)error {
  int ret = rmdir([[self sourcePath:path] UTF8String]);
  if (ret < 0) {
    *error = [NSError errorWithPOSIXCode:errno];
    return NO;
  }
  return YES;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
  if ([[NSFileManager defaultManager] removeItemAtPath:[self sourcePath:path]
                                                 error:error]) {
    dispatch_async(cachingQueue, ^{
      [[NSFileManager defaultManager] removeItemAtPath:[self sourcePath:path]
                                                 error:nil];
    });
    return YES;
  } else
    return NO;
}

#pragma mark Linking an Item (Optional)

// TODO: Maybe Write Implementation
//- (BOOL)linkItemAtPath:(NSString *)path
//                toPath:(NSString *)otherPath
//                 error:(NSError **)error {
//  return NO; 
//}

#pragma mark Symbolic Links (Optional)

// TODO: Maybe Write Implementation
//- (BOOL)createSymbolicLinkAtPath:(NSString *)path 
//             withDestinationPath:(NSString *)otherPath
//                           error:(NSError **)error {
//  return NO;
//}

// TODO: Maybe Write Implementation
//- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path
//                                        error:(NSError **)error {
//  *error = [NSError errorWithPOSIXCode:ENOENT];
//  return nil;
//}

#pragma mark Extended Attributes (Optional)

// TODO: Maybe Write Implementation
//- (NSArray *)extendedAttributesOfItemAtPath:(NSString *)path error:(NSError **)error {
//  return [NSArray array];  // No extended attributes.
//}

// TODO: Maybe Write Implementation
//- (NSData *)valueOfExtendedAttribute:(NSString *)name 
//                        ofItemAtPath:(NSString *)path
//                            position:(off_t)position
//                               error:(NSError **)error {
//  *error = [NSError errorWithPOSIXCode:ENOATTR];
//  return nil;
//}

// TODO: Maybe Write Implementation
//- (BOOL)setExtendedAttribute:(NSString *)name
//                ofItemAtPath:(NSString *)path
//                       value:(NSData *)value
//                    position:(off_t)position
//                     options:(int)options
//                       error:(NSError **)error {
//  return YES;
//}

// TODO: Maybe Write Implementation
//- (BOOL)removeExtendedAttribute:(NSString *)name
//                   ofItemAtPath:(NSString *)path
//                          error:(NSError **)error {
//  return YES;
//}

#pragma mark FinderInfo and ResourceFork (Optional)

// TODO: Maybe Write Implementation
//- (NSDictionary *)finderAttributesAtPath:(NSString *)path 
//                                   error:(NSError **)error {
//  return [NSDictionary dictionary];
//}

// TODO: Maybe Write Implementation
//- (NSDictionary *)resourceAttributesAtPath:(NSString *)path
//                                     error:(NSError **)error {
//  return [NSDictionary dictionary];
//}

@end
