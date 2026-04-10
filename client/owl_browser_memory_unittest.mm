// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLBrowserMemory.h"
#include "testing/gtest/include/gtest/gtest.h"
namespace owl { namespace {

TEST(OWLMemoryEntryTest, CreateEntry) {
  OWLMemoryEntry* e = [OWLMemoryEntry entryWithURL:@"https://ex.com"
      title:@"Example" summary:@"A page" tags:@[@"web"]];
  EXPECT_TRUE([e.url isEqualToString:@"https://ex.com"]);
  EXPECT_TRUE([e.title isEqualToString:@"Example"]);
  EXPECT_TRUE([e.summary isEqualToString:@"A page"]);
  EXPECT_EQ(e.tags.count, 1u);
  EXPECT_NE(e.visitedAt, nil);
}

TEST(OWLBrowserMemoryTest, InitiallyEmpty) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  EXPECT_EQ(mem.entryCount, 0u);
}

TEST(OWLBrowserMemoryTest, AddEntry) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"A" summary:@"S" tags:@[]]];
  EXPECT_EQ(mem.entryCount, 1u);
}

TEST(OWLBrowserMemoryTest, RemoveEntry) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  OWLMemoryEntry* e = [OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"A" summary:@"S" tags:@[]];
  [mem addEntry:e];
  [mem removeEntry:e.entryId];
  EXPECT_EQ(mem.entryCount, 0u);
}

TEST(OWLBrowserMemoryTest, ClearAll) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  for (int i = 0; i < 5; ++i) {
    [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
        title:@"A" summary:@"S" tags:@[]]];
  }
  [mem clearAll];
  EXPECT_EQ(mem.entryCount, 0u);
}

TEST(OWLBrowserMemoryTest, SearchByTitle) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"React Tutorial" summary:@"Learn React" tags:@[]]];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://b.com"
      title:@"Vue Guide" summary:@"Learn Vue" tags:@[]]];

  NSArray* results = [mem searchWithQuery:@"React"];
  EXPECT_EQ(results.count, 1u);
}

TEST(OWLBrowserMemoryTest, SearchBySummary) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"Page" summary:@"Contains important data" tags:@[]]];

  NSArray* results = [mem searchWithQuery:@"important"];
  EXPECT_EQ(results.count, 1u);
}

TEST(OWLBrowserMemoryTest, SearchCaseInsensitive) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"UPPER Case" summary:@"S" tags:@[]]];
  NSArray* results = [mem searchWithQuery:@"upper"];
  EXPECT_EQ(results.count, 1u);
}

TEST(OWLBrowserMemoryTest, SearchEmptyQueryReturnsAll) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"A" summary:@"S" tags:@[]]];
  NSArray* results = [mem searchWithQuery:@""];
  EXPECT_EQ(results.count, 1u);
}

TEST(OWLBrowserMemoryTest, EntriesReturnsCopy) {
  OWLBrowserMemory* mem = [[OWLBrowserMemory alloc] init];
  [mem addEntry:[OWLMemoryEntry entryWithURL:@"https://a.com"
      title:@"A" summary:@"S" tags:@[]]];
  NSArray* e = mem.entries;
  [mem clearAll];
  EXPECT_EQ(e.count, 1u);
  EXPECT_EQ(mem.entryCount, 0u);
}

} }
