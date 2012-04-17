//
//  main.m
//  cachefs
//
//  Created by Matias Eyzaguirre on 4/14/12.
//  Copyright (c) 2012 J. Willard Marriott Library. All rights reserved.
//

#import <sys/stat.h>
#import <Foundation/Foundation.h>
#import <OSXFUSE/GMUserFileSystem.h>
#import "CacheFS.h"

int main(int argc, char* argv[], char* envp[], char** exec_path) {
  @autoreleasepool {
    
    NSUserDefaults *args = [NSUserDefaults standardUserDefaults];
    NSString* mountPath = [args stringForKey:@"mountPath"];
    NSString* iconPath = [args stringForKey:@"volicon"];
    NSString* sourcePath = [args stringForKey:@"sourcePath"];
    if (!mountPath || [mountPath isEqualToString:@""]) {
      printf("\nUsage: %s -mountPath <path> [-volicon <path>]\n", argv[0]);
      printf("  -mountPath: Mount point to use.\n");
      printf("Ex: %s -mountPath /Volumes/cachefs\n\n", argv[0]);
      return 0;
    }
    if (!iconPath) {
      // We check for a volume icon embedded as our resource fork.
      char program_path[PATH_MAX] = { 0 };
      if (realpath(*exec_path, program_path)) {
        iconPath = [NSString stringWithFormat:@"%s/..namedfork/rsrc", program_path];
        struct stat stat_buf;
        memset(&stat_buf, 0, sizeof(stat_buf));
        if (stat([iconPath UTF8String], &stat_buf) != 0 || stat_buf.st_size <= 0) {
          iconPath = nil;  // We found an exec path, but the resource fork is empty.
        }
      }
    }
    
    CacheFS* fs = 
    [[CacheFS alloc] initWithPath:sourcePath];
    GMUserFileSystem* userFS = [[GMUserFileSystem alloc] initWithDelegate:fs 
                                                             isThreadSafe:NO];
    
    NSMutableArray* options = [NSMutableArray array];
    if (iconPath != nil) {
      NSString* volArg = [NSString stringWithFormat:@"volicon=%@", iconPath];
      [options addObject:volArg];
    }
    [options addObject:@"volname=cachefs"];
    // [options addObject:@"rdonly"];  <-- Uncomment to mount read-only.
    
    [userFS mountAtPath:mountPath 
            withOptions:options 
       shouldForeground:YES 
        detachNewThread:NO];
    
    [fs cleanUp];
  }
  return 0;
}

