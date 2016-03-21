//
//  RMHeapEnumerator.m
//  HeapInspectorExample
//
//  Created by Christian Menschel on 22.08.14.
//  Copyright (c) 2014 tapwork. All rights reserved.
//
//  Inspired by Flipboard's FLEX and HeapEnumerator
//  See more: https://github.com/Flipboard/FLEX/blob/master/Classes/Utility/FLEXHeapEnumerator.m
//

#import "HINSPHeapStackInspector.h"
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <NSObject+HeapInspector.h>

static CFMutableSetRef classesLoadedInRuntime = NULL;
static NSSet *heapShotOfLivingObjects = nil;

// Mimics the objective-c object stucture for checking if a range of memory is an object.
typedef struct {
    Class isa;
} rm_maybe_object_t;

@implementation HINSPHeapStackInspector

static inline kern_return_t memory_reader(task_t task, vm_address_t remote_address, vm_size_t size, void **local_memory)
{
    *local_memory = (void *)remote_address;
    return KERN_SUCCESS;
}

static inline void range_callback(task_t task,
                                  void *context,
                                  unsigned type,
                                  vm_range_t *ranges,
                                  unsigned rangeCount)
{
    RMHeapEnumeratorBlock block = (__bridge RMHeapEnumeratorBlock)context;
    if (!block) {
        return;
    }
    for (unsigned int i = 0; i < rangeCount; i++) {
        vm_range_t range = ranges[i];
        rm_maybe_object_t *object = (rm_maybe_object_t *)range.address;
        Class tryClass = NULL;
#ifdef __arm64__
        // See http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html
        extern uint64_t objc_debug_isa_class_mask WEAK_IMPORT_ATTRIBUTE;
        tryClass = (__bridge Class)((void *)((uint64_t)object->isa & objc_debug_isa_class_mask));
#else
        tryClass = object->isa;
#endif
        if (tryClass &&
            CFSetContainsValue(classesLoadedInRuntime, (__bridge const void *)(tryClass)) &&
            canRecordObject((__bridge id)object)) {
            block((__bridge id)object);
        }
    }
}

+ (void)enumerateLiveObjectsUsingBlock:(RMHeapEnumeratorBlock)block
{
    if (!block) {
        return;
    }
    
    // Refresh the class list on every call in case classes are added to the runtime.
    [self updateRegisteredClasses];
    
    // For another exmple of enumerating through malloc ranges (which helped my understanding of the api) see:
    // http://llvm.org/svn/llvm-project/lldb/tags/RELEASE_34/final/examples/darwin/heap_find/heap/heap_find.cpp
    // Also https://gist.github.com/samdmarshall/17f4e66b5e2e579fd396
    // or http://www.opensource.apple.com/source/Libc/Libc-167/gen.subproj/malloc.c
    vm_address_t *zones = NULL;
    mach_port_t task = mach_task_self();
    unsigned int zoneCount = 0;
    kern_return_t result = malloc_get_all_zones(task, memory_reader, &zones, &zoneCount);
    if (result == KERN_SUCCESS) {
        for (unsigned i = 0; i < zoneCount; i++) {
            malloc_zone_t *zone = (malloc_zone_t *)zones[i];
            if (zone != NULL && zone->introspect != NULL) {
                zone->introspect->enumerator(task,
                                             (__bridge void *)(block),
                                             MALLOC_PTR_IN_USE_RANGE_TYPE,
                                             (vm_address_t)zone,
                                             memory_reader,
                                             range_callback);
            }
        }
    }
}

+ (void)updateRegisteredClasses
{
    if (!classesLoadedInRuntime) {
        classesLoadedInRuntime = CFSetCreateMutable(NULL, 0, NULL);
    } else {
        CFSetRemoveAllValues(classesLoadedInRuntime);
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        CFSetAddValue(classesLoadedInRuntime, (__bridge const void *)(classes[i]));
    }
    free(classes);
}

#pragma mark - Public

+ (void)performHeapShot
{
    heapShotOfLivingObjects = [[self class] heap];
}

+ (void)reset
{
    heapShotOfLivingObjects = nil;
    classesLoadedInRuntime = NULL;
}

+ (NSSet *)recordedHeap
{
    NSMutableSet *endLiveObjects = [[[self class] heap] mutableCopy];
    [endLiveObjects minusSet:heapShotOfLivingObjects];
    NSSet *recordedObjects = [NSSet setWithSet:endLiveObjects];
    heapShotOfLivingObjects = recordedObjects;
    return recordedObjects;
}

+ (NSSet *)heap
{
    NSMutableSet *objects = [NSMutableSet set];
    [HINSPHeapStackInspector enumerateLiveObjectsUsingBlock:^(__unsafe_unretained id object) {
        // We cannot store the object itself -  We want to avoid any retain calls.
        // We store the class name + pointer
        NSString *string = [NSString stringWithFormat:@"%s: %p",
                            object_getClassName(object),
                            object];
        [objects addObject:string];
    }];
    
    return objects;
}

+ (id)objectForPointer:(NSString *)pointer
{
    for (id object in heapShotOfLivingObjects) {
        if ([pointer isEqualToString:[NSString stringWithFormat:@"%p",object]]) {
            return object;
        }
    }
    
    return nil;
}

@end
