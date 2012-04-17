//
//  CacheFS.h
//  cachefs
//
//  Created by Matias Eyzaguirre on 4/14/12.
//  Copyright (c) 2012 J. Willard Marriott Library. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface CacheFS : NSObject

-(id)initWithPath:(NSString*)path;

// you MUST NOT perform filesystem operations on this object after this method has been called
-(void)cleanUp;

@end
