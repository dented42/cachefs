//
//  dispatch_utils.c
//  cachefs
//
//  Created by Matias Eyzaguirre on 4/15/12.
//  Copyright (c) 2012 J. Willard Marriott Library. All rights reserved.
//

#include <stdio.h>

#include "dispatch_utils.h"

void dispatch_group_barrier_async(dispatch_group_t group,
                                  dispatch_queue_t queue,
                                  dispatch_block_t block) {
  dispatch_group_enter(group);
  dispatch_barrier_async(queue, ^{
    block();
    dispatch_group_leave(group);
  });
}

void dispatch_group_barrier_sync(dispatch_group_t group,
                                  dispatch_queue_t queue,
                                  dispatch_block_t block) {
  dispatch_group_enter(group);
  dispatch_barrier_sync(queue, ^{
    block();
    dispatch_group_leave(group);
  });
}