// Copyright 2026 AntlerAI. All rights reserved.
// Phase 9: Browser Memory — stores browsing context for AI recall.
#ifndef THIRD_PARTY_OWL_CLIENT_OWL_BROWSER_MEMORY_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_BROWSER_MEMORY_H_
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface OWLMemoryEntry : NSObject
@property(nonatomic, readonly, copy) NSString* entryId;
@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy) NSString* summary;
@property(nonatomic, readonly) NSDate* visitedAt;
@property(nonatomic, readonly, copy) NSArray<NSString*>* tags;
+ (instancetype)entryWithURL:(NSString*)url
                       title:(NSString*)title
                     summary:(NSString*)summary
                        tags:(NSArray<NSString*>*)tags;
@end

@class OWLBrowserMemory;

@protocol OWLBrowserMemoryDelegate <NSObject>
@optional
- (void)browserMemory:(OWLBrowserMemory*)memory didAddEntry:(OWLMemoryEntry*)entry;
- (void)browserMemory:(OWLBrowserMemory*)memory didRemoveEntry:(NSString*)entryId;
@end

__attribute__((visibility("default")))
@interface OWLBrowserMemory : NSObject
@property(weak, nonatomic, nullable) id<OWLBrowserMemoryDelegate> delegate;
@property(nonatomic, readonly, copy) NSArray<OWLMemoryEntry*>* entries;
- (void)addEntry:(OWLMemoryEntry*)entry;
- (void)removeEntry:(NSString*)entryId;
- (void)clearAll;
- (NSArray<OWLMemoryEntry*>*)searchWithQuery:(NSString*)query;
@property(nonatomic, readonly) NSUInteger entryCount;
@end

NS_ASSUME_NONNULL_END
#endif
