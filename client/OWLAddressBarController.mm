// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAddressBarController.h"
@implementation OWLAddressBarController

namespace {

BOOL IsAllASCIICharactersInSet(NSString* input, NSCharacterSet* set) {
  return [[input stringByTrimmingCharactersInSet:set] length] == 0;
}

BOOL IsValidIPv4Address(NSString* host) {
  NSArray<NSString*>* parts = [host componentsSeparatedByString:@"."];
  if (parts.count != 4) {
    return NO;
  }

  for (NSString* part in parts) {
    if (part.length == 0 || part.length > 3) {
      return NO;
    }
    NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
    if (!IsAllASCIICharactersInSet(part, digits)) {
      return NO;
    }
    NSInteger value = part.integerValue;
    if (value < 0 || value > 255) {
      return NO;
    }
  }
  return YES;
}

NSString* EncodeSearchQuery(NSString* query) {
  NSMutableCharacterSet* allowed =
      [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
  [allowed removeCharactersInString:@"+=&"];
  return [query stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

}  // namespace

// BH-013: Explicitly encode search query terms so '+', '&', '=' are preserved
// as user input and not interpreted as URL query syntax.
+ (nullable NSURL*)searchURLForQuery:(NSString*)query {
  NSString* encoded = EncodeSearchQuery(query);
  if (!encoded) {
    return nil;
  }
  NSString* raw = [@"https://www.google.com/search?q="
      stringByAppendingString:encoded];
  return [NSURL URLWithString:raw];
}

+ (nullable NSURL*)urlFromInput:(NSString*)input {
  NSString* trimmed = [input stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0) return nil;
  if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"] ||
      [trimmed hasPrefix:@"data:"]) {
    return [NSURL URLWithString:trimmed];
  }
  if ([self inputLooksLikeURL:trimmed]) {
    return [NSURL URLWithString:[@"https://" stringByAppendingString:trimmed]];
  }
  return [self searchURLForQuery:trimmed];
}

// BH-020: URL heuristic.
// Returns YES for scheme://, localhost, IPv4, and dotted hosts with an
// alphabetic suffix (e.g. a.b.c). Returns NO for plain words, spaces,
// and dotted numeric version strings like 1.0.0.
+ (BOOL)inputLooksLikeURL:(NSString*)input {
  if ([input containsString:@" "]) return NO;
  if ([input containsString:@"://"]) return YES;
  if ([input hasPrefix:@"localhost"]) return YES;

  // Extract host (strip path and port first).
  NSString* host = input;
  NSRange slashRange = [host rangeOfString:@"/"];
  if (slashRange.location != NSNotFound) {
    host = [host substringToIndex:slashRange.location];
  }
  NSRange colonRange = [host rangeOfString:@":" options:NSBackwardsSearch];
  if (colonRange.location != NSNotFound) {
    host = [host substringToIndex:colonRange.location];
  }

  if (![host containsString:@"."]) {
    return NO;
  }

  // IPv4 literal.
  if (IsValidIPv4Address(host)) {
    return YES;
  }

  // Reject dotted numeric strings (e.g. version numbers like 1.0.0).
  NSCharacterSet* numericDot =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
  if (IsAllASCIICharactersInSet(host, numericDot)) {
    return NO;
  }

  // Accept dotted hosts with alphabetic suffix (e.g. a.b.c / example.internal).
  NSRange lastDot = [host rangeOfString:@"." options:NSBackwardsSearch];
  if (lastDot.location == NSNotFound ||
      lastDot.location + 1 >= host.length) {
    return NO;
  }

  NSString* suffix = [host substringFromIndex:lastDot.location + 1];
  NSCharacterSet* letters = [NSCharacterSet letterCharacterSet];
  for (NSUInteger i = 0; i < suffix.length; ++i) {
    unichar c = [suffix characterAtIndex:i];
    if ([letters characterIsMember:c]) {
      return YES;
    }
  }

  return NO;
}
@end
