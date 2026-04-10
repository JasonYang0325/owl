// Copyright 2026 AntlerAI. All rights reserved.

#import "third_party/owl/host/owl_application_mac.h"

#include "base/auto_reset.h"
#include "base/observer_list.h"
#include "content/public/browser/native_event_processor_mac.h"
#include "content/public/browser/native_event_processor_observer_mac.h"

@interface OWLApplication () <NativeEventProcessor>
@end

@implementation OWLApplication {
  base::ObserverList<content::NativeEventProcessorObserver>::Unchecked
      _observers;
}

- (void)sendEvent:(NSEvent*)event {
  content::ScopedNotifyNativeEventProcessorObserver scopedObserverNotifier(
      &_observers, event);
  [super sendEvent:event];
}

- (void)addNativeEventProcessorObserver:
    (content::NativeEventProcessorObserver*)observer {
  _observers.AddObserver(observer);
}

- (void)removeNativeEventProcessorObserver:
    (content::NativeEventProcessorObserver*)observer {
  _observers.RemoveObserver(observer);
}

@end
