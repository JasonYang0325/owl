// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLBrowserMemory.h"
@implementation OWLMemoryEntry
@synthesize entryId = _entryId, url = _url, title = _title;
@synthesize summary = _summary, visitedAt = _visitedAt, tags = _tags;
+ (instancetype)entryWithURL:(NSString*)url title:(NSString*)title
                     summary:(NSString*)summary tags:(NSArray<NSString*>*)tags {
  OWLMemoryEntry* e = [[OWLMemoryEntry alloc] init];
  e->_entryId = [[NSUUID UUID] UUIDString];
  e->_url = [url copy];
  e->_title = [title copy];
  e->_summary = [summary copy];
  e->_visitedAt = [NSDate date];
  e->_tags = [tags copy];
  return e;
}
@end

@implementation OWLBrowserMemory {
  NSMutableArray<OWLMemoryEntry*>* _entries;
}
@synthesize delegate = _delegate;
- (instancetype)init {
  self = [super init];
  if (self) { _entries = [NSMutableArray array]; }
  return self;
}
- (NSArray<OWLMemoryEntry*>*)entries { return [_entries copy]; }
- (NSUInteger)entryCount { return _entries.count; }
// BH-015: Main-thread assertions for collection mutation.
- (void)addEntry:(OWLMemoryEntry*)entry {
  NSAssert([NSThread isMainThread], @"Must be called on main thread");
  if (entry) {
    [_entries addObject:entry];
    if ([_delegate respondsToSelector:@selector(browserMemory:didAddEntry:)]) {
      [_delegate browserMemory:self didAddEntry:entry];
    }
  }
}
- (void)removeEntry:(NSString*)entryId {
  NSAssert([NSThread isMainThread], @"Must be called on main thread");
  [_entries filterUsingPredicate:
      [NSPredicate predicateWithBlock:^BOOL(OWLMemoryEntry* e, NSDictionary*) {
        return ![e.entryId isEqualToString:entryId];
      }]];
  if ([_delegate respondsToSelector:@selector(browserMemory:didRemoveEntry:)]) {
    [_delegate browserMemory:self didRemoveEntry:entryId];
  }
}
- (void)clearAll {
  NSAssert([NSThread isMainThread], @"Must be called on main thread");
  [_entries removeAllObjects];
}
- (NSArray<OWLMemoryEntry*>*)searchWithQuery:(NSString*)query {
  NSAssert([NSThread isMainThread], @"Must be called on main thread");
  if (query.length == 0) return [_entries copy];
  NSString* lower = [query lowercaseString];
  NSMutableArray* results = [NSMutableArray array];
  for (OWLMemoryEntry* e in _entries) {
    if ([[e.title lowercaseString] containsString:lower] ||
        [[e.summary lowercaseString] containsString:lower] ||
        [[e.url lowercaseString] containsString:lower]) {
      [results addObject:e];
    }
  }
  return [results copy];
}
@end
