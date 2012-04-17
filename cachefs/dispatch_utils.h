//
//  dispatch_utils.h
//  cachefs
//
//  Created by Matias Eyzaguirre on 4/15/12.
//  Copyright (c) 2012 J. Willard Marriott Library. All rights reserved.
//

#ifndef cachefs_dispatch_utils_h
#define cachefs_dispatch_utils_h

#include <dispatch/dispatch.h>

void dispatch_group_barrier_async(dispatch_group_t group,
                                  dispatch_queue_t queue,
                                  dispatch_block_t block);

void dispatch_group_barrier_sync(dispatch_group_t group,
                                  dispatch_queue_t queue,
                                  dispatch_block_t block);

#endif
