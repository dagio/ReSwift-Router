//
//  Router.swift
//  Meet
//
//  Created by Benjamin Encz on 11/11/15.
//  Copyright © 2015 DigiTales. All rights reserved.
//

import Foundation
import ReSwift

open class Router<State: StateType>: StoreSubscriber {

    public typealias NavigationStateSelector = (State) -> NavigationState

    var store: Store<State>
    var lastNavigationState = NavigationState()
    var routables: [Routable] = []
    let waitForRoutingCompletionQueue = DispatchQueue(label: "WaitForRoutingCompletionQueue", attributes: [])

    public init(store: Store<State>, rootRoutable: Routable,  stateSelector: @escaping NavigationStateSelector) {
        self.store = store 
        self.routables.append(rootRoutable)

        self.store.subscribe(self, selector: stateSelector)
    }

    open func newState(state: NavigationState) {
        let routingActions = Router.routingActionsForTransitionFrom(
            lastNavigationState.route, newRoute: state.route)

        routingActions.forEach { routingAction in

            let semaphore = DispatchSemaphore(value: 0)

            // Dispatch all routing actions onto this dedicated queue. This will ensure that
            // only one routing action can run at any given time. This is important for using this
            // Router with UI frameworks. Whenever a navigation action is triggered, this queue will
            // block (using semaphore_wait) until it receives a callback from the Routable 
            // indicating that the navigation action has completed
            waitForRoutingCompletionQueue.async {
                switch routingAction {

                case let .pop(responsibleRoutableIndex, segmentToBePopped):
                    DispatchQueue.main.async {
                        self.routables[responsibleRoutableIndex]
                            .popRouteSegment(
                                segmentToBePopped,
                                animated: state.changeRouteAnimated) {
                                    semaphore.signal()
                        }

                        self.routables.remove(at: responsibleRoutableIndex + 1)
                    }

                case let .change(responsibleRoutableIndex, segmentToBeReplaced, newSegment):
                    DispatchQueue.main.async {
                        self.routables[responsibleRoutableIndex + 1] =
                            self.routables[responsibleRoutableIndex]
                                .changeRouteSegment(
                                    segmentToBeReplaced,
                                    to: newSegment,
                                    animated: state.changeRouteAnimated) {
                                        semaphore.signal()
                        }
                    }

                case let .push(responsibleRoutableIndex, segmentToBePushed):
                    DispatchQueue.main.async {
                        self.routables.append(
                            self.routables[responsibleRoutableIndex]
                                .pushRouteSegment(
                                    segmentToBePushed,
                                    animated: state.changeRouteAnimated) {
                                        semaphore.signal()
                            }
                        )
                    }
                }

                let waitUntil = DispatchTime.now() + Double(Int64(3 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)

                let result = semaphore.wait(timeout: waitUntil)

                if case .timedOut = result {
                    print("[ReSwiftRouter]: Router is stuck waiting for a" +
                        " completion handler to be called. Ensure that you have called the" +
                        " completion handler in each Routable element.")
                    print("Set a symbolic breakpoint for the `ReSwiftRouterStuck` symbol in order" +
                        " to halt the program when this happens")
                    ReSwiftRouterStuck()
                }
            }

        }

        lastNavigationState = state
    }

    // MARK: Route Transformation Logic

    /// Find the last common sub route between two routes
    static func largestCommonSubRouteElementIndex(_ oldRoute: Route, newRoute: Route) -> Int {
            var largestCommonSubRouteElementIndex = -1

            while largestCommonSubRouteElementIndex + 1 < newRoute.count &&
                  largestCommonSubRouteElementIndex + 1 < oldRoute.count &&
                  newRoute[largestCommonSubRouteElementIndex + 1] == oldRoute[largestCommonSubRouteElementIndex + 1] {
                    largestCommonSubRouteElementIndex += 1
            }

            return largestCommonSubRouteElementIndex
    }

    // Maps Route index to Routable index. Routable index is offset by 1 because the root Routable
    // is not represented in the route, e.g.
    // route = ["tabBar"]
    // routables = [RootRoutable, TabBarRoutable]
    static func routableIndexForRouteSegment(_ segment: Int) -> Int {
        return segment + 1
    }

    /**
     Build the list of actions required in order to proceed to the new route

     @param oldRoute The current route
     @param newRoute The router to navigate to
     @return The list of routing actions
    */
    static func routingActionsForTransitionFrom(_ oldRoute: Route, newRoute: Route) -> [RoutingActions] {

        // The actions (push, pop or change) required in order to proceed to the new route
        var routingActions: [RoutingActions] = []

        // Find the last common sub route between two routes
        // -1 = no common
        //  0 = the first element is common
        //  1 = the 2 first elements are common
        //  ...
        let commonSubRouteLatestElementIndex = largestCommonSubRouteElementIndex(oldRoute, newRoute: newRoute)
        let commonSubRouteElementsCount = commonSubRouteLatestElementIndex + 1

        // If the common sub route elements count is equal to
        // the old route elements count and
        // the new route elements count then
        // it means there are no change of route. So no actions are required
        if commonSubRouteElementsCount == oldRoute.count
        && commonSubRouteElementsCount == newRoute.count {
            return []
        }

        // Keeps track which element of the routes we are working on
        // We start at the last element of the old route
        var routeBuildingIndex = oldRoute.count - 1

        // Pop all route segments of the old route that are no longer in the new route
        // Stop one element ahead of the commonSubRoute. When we are one element ahead of the
        // common sub route we have three options:
        //
        // 1. The old route had an element after the commonSubRoute and the new route does not
        //    we need to pop the route segment after the commonSubRoute
        // 2. The old route had no element after the commonSubRoute and the new route does,
        //    we need to push the route segment(s) after the commonSubRoute
        // 3. The new route has a different element after the commonSubRoute, we need to replace
        //    the old route element with the new one
        //
        // Example:
        //    oldRoute:                      [home, details, help]
        //    newRoute:                      [home]
        //    commonSubRouteElementIndex:    0
        //    routeBuildingIndex:            2
        //
        // In the previous example, only "help" will be pop because we stop one element
        // ahead of the commonSubRoute
        //
        while routeBuildingIndex > commonSubRouteLatestElementIndex + 1 {
            let routeSegmentToPop = oldRoute[routeBuildingIndex]

            let popAction = RoutingActions.pop(
                responsibleRoutableIndex: routableIndexForRouteSegment(routeBuildingIndex - 1),
                segmentToBePopped: routeSegmentToPop
            )

            routingActions.append(popAction)
            routeBuildingIndex -= 1
        }

        // This is the 1. case:
        // "The old route had an element after the commonSubRoute and the new route does not
        //  we need to pop the route segment after the commonSubRoute"
        if oldRoute.count > newRoute.count {
            let popAction = RoutingActions.pop(
                responsibleRoutableIndex: routableIndexForRouteSegment(routeBuildingIndex - 1),
                segmentToBePopped: oldRoute[routeBuildingIndex]
            )

            routingActions.append(popAction)
            routeBuildingIndex -= 1
        }
        // This is the 3. case:
        // "The new route has a different element after the commonSubRoute, we need to replace
        //  the old route element with the new one"
        // 
        // Example 1:
        //    oldRoute:                     [home, details]
        //    newRoute:                     [home, help]
        //    commonSubRouteElementIndex:   0
        // Example 2:
        //    oldRoute:                     [details]
        //    newRoute:                     [help]
        //    commonSubRouteElementIndex:   -1
        //
        else if oldRoute.count > (commonSubRouteLatestElementIndex + 1)
             && newRoute.count > (commonSubRouteLatestElementIndex + 1) {

            let changeAction = RoutingActions.change(
                responsibleRoutableIndex: routableIndexForRouteSegment(commonSubRouteLatestElementIndex), // Ex1 : home
                segmentToBeReplaced: oldRoute[commonSubRouteLatestElementIndex + 1], // Ex1 : details
                newSegment: newRoute[commonSubRouteLatestElementIndex + 1]) // Ex1 : help

            routingActions.append(changeAction)
        }

        // Push elements from new Route that weren't in old Route, this covers
        // the 2. case:
        // "The old route had no element after the commonSubRoute and the new route does,
        //  we need to push the route segment(s) after the commonSubRoute"
        let newRouteIndex = newRoute.count - 1

        while routeBuildingIndex < newRouteIndex {
            let routeSegmentToPush = newRoute[routeBuildingIndex + 1]

            let pushAction = RoutingActions.push(
                responsibleRoutableIndex: routableIndexForRouteSegment(routeBuildingIndex),
                segmentToBePushed: routeSegmentToPush
            )

            routingActions.append(pushAction)
            routeBuildingIndex += 1
        }

        return routingActions
    }

}

func ReSwiftRouterStuck() {}

enum RoutingActions {
    case push(responsibleRoutableIndex: Int, segmentToBePushed: RouteElementIdentifier)
    case pop(responsibleRoutableIndex: Int, segmentToBePopped: RouteElementIdentifier)
    case change(responsibleRoutableIndex: Int, segmentToBeReplaced: RouteElementIdentifier,
                    newSegment: RouteElementIdentifier)
}
