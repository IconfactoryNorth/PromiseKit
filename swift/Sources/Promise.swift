import Foundation
import UIKit

enum State {   //TODO generics! Type T! Nested! (can't now due to compiler bugs)
    case Pending
    case Fulfilled(Any)
    case Rejected(NSError)
}


//TODO private
func dispatch_promise<T>(to queue:dispatch_queue_t = dispatch_get_global_queue(0, 0), block:(fulfiller: (T)->Void, rejecter: (NSError)->Void) -> ()) -> Promise<T> {
    return Promise<T> { (fulfiller, rejecter) in
        dispatch_async(queue) {
            block(fulfiller, rejecter)
        }
    }
}

//TODO private
func dispatch_main(block: ()->()) {
    dispatch_async(dispatch_get_main_queue(), block)
}


class Promise<T> {
    var _handlers:[() -> Void] = []
    var _state:State = .Pending

    var rejected:Bool {
        switch _state {
            case .Fulfilled, .Pending: return false
            case .Rejected: return true;
        }
    }
    var fulfilled:Bool {
        switch _state {
            case .Rejected, .Pending: return false
            case .Fulfilled: return true;
        }
    }
    var pending:Bool {
        switch _state {
            case .Rejected, .Fulfilled: return false
            case .Pending: return true;
        }
    }

    /**
      returns the fulfilled value unless the Promise is not fulfilled
      in which case returns `nil`
     */
    var value:T? {
        switch _state {
        case .Fulfilled(let value):
            return value as? T
        default:
            return nil
        }
    }

    init(_ body:(fulfiller:(T) -> Void, rejecter:(NSError) -> Void) -> Void) {
        func recurse() {
            for handler in _handlers { handler() }
            _handlers.removeAll(keepCapacity: false)
        }
        func rejecter(err: NSError) {
            if self.pending {
                self._state = .Rejected(err);
                recurse();
            }
        }
        func fulfiller(obj: T) {
            if self.pending {
                self._state = .Fulfilled(obj);
                recurse()
            }
        }
        body(fulfiller, rejecter)
    }

    class func defer() -> (promise:Promise, fulfiller:(T) -> Void, rejecter:(NSError) -> Void) {
        var f: ((T) -> Void)?
        var r: ((NSError) -> Void)?
        let p = Promise{ f = $0; r = $1 }
        return (p, f!, r!)
    }

    init(value:T) {
        self._state = .Fulfilled(value)
    }

    init(error:NSError) {
        self._state = .Rejected(error)
    }

    func then<U>(onQueue q:dispatch_queue_t = dispatch_get_main_queue(), body:(T) -> U) -> Promise<U> {
        switch _state {
        case .Rejected(let error):
            return Promise<U>(error: error);
        case .Fulfilled(let value):
            return dispatch_promise(to:q){ d in d.fulfiller(body(value as T)) }
        case .Pending:
            return Promise<U>{ (fulfiller, rejecter) in
                self._handlers.append {
                    switch self._state {
                    case .Rejected(let error):
                        rejecter(error)
                    case .Fulfilled(let value):
                        dispatch_async(q) {
                            fulfiller(body(value as T))
                        }
                    case .Pending:
                        abort()
                    }
                }
            }
        }
    }

    func then<U>(onQueue q:dispatch_queue_t = dispatch_get_main_queue(), body:(T) -> Promise<U>) -> Promise<U> {

        func bind(value:T, fulfiller: (U)->(), rejecter: (NSError)->()) {
            let promise = body(value)
            switch promise._state {
            case .Rejected(let error):
                rejecter(error)
            case .Fulfilled(let value):
                fulfiller(value as U)
            case .Pending:
                promise._handlers.append{
                    switch promise._state {
                    case .Rejected(let error):
                        rejecter(error)
                    case .Fulfilled(let value):
                        fulfiller(value as U)
                    case .Pending:
                        abort()
                    }
                }
            }
        }

        switch _state {
        case .Rejected(let error):
            return Promise<U>(error: error);
        case .Fulfilled(let value):
            return dispatch_promise(to:q){
                bind(value as T, $0, $1)
            }
        case .Pending:
            return Promise<U>{ (fulfiller, rejecter) in
                self._handlers.append{
                    switch self._state {
                    case .Pending:
                        abort()
                    case .Fulfilled(let value):
                        dispatch_async(q){
                            bind(value as T, fulfiller, rejecter)
                        }
                    case .Rejected(let error):
                        rejecter(error)
                    }
                }
            }
        }
    }

    func catch(onQueue:dispatch_queue_t = dispatch_get_main_queue(), body:(NSError) -> T) -> Promise<T> {
        switch _state {
        case .Fulfilled(let value):
            return Promise(value:value as T)
        case .Rejected(let error):
            return dispatch_promise(to:onQueue){ (fulfiller, _) -> Void in fulfiller(body(error)) }
        case .Pending:
            return Promise<T>{ (fulfiller, rejecter) in
                self._handlers.append {
                    switch self._state {
                    case .Fulfilled(let value):
                        fulfiller(value as T)
                    case .Rejected(let error):
                        dispatch_async(onQueue){ fulfiller(body(error)) }
                    case .Pending:
                        abort()
                    }
                }
            }
        }
    }

    func catch(onQueue:dispatch_queue_t = dispatch_get_main_queue(), body:(NSError) -> Void) -> Void {
        switch _state {
        case .Rejected(let error):
            dispatch_async(onQueue, {
                body(error)
            })
        case .Fulfilled:
            let noop = 0
        case .Pending:
            self._handlers.append({
                switch self._state {
                case .Rejected(let error):
                    dispatch_async(onQueue){ body(error) }
                case .Fulfilled:
                    let noop = 0
                case .Pending:
                    abort()
                }
            })
        }
    }

    func catch<T>(onQueue q:dispatch_queue_t = dispatch_get_main_queue(), body:(NSError) -> Promise<T>) -> Promise<T> {

        func bind(error:NSError, fulfiller: (T)->(), rejecter: (NSError)->()) {
            let promise = body(error)
            switch promise._state {
            case .Rejected(let error):
                rejecter(error)
            case .Fulfilled(let value):
                fulfiller(value as T)
            case .Pending:
                promise._handlers.append{
                    switch promise._state {
                    case .Rejected(let error):
                        rejecter(error)
                    case .Fulfilled(let value):
                        fulfiller(value as T)
                    case .Pending:
                        abort()
                    }
                }
            }
        }

        switch _state {
        case .Rejected(let error):
            return dispatch_promise(to:q){
                bind(error, $0, $1)
            }
        case .Fulfilled(let value):
            return Promise<T>(value:value as T)
        case .Pending:
            return Promise<T>{ (fulfiller, rejecter) in
                self._handlers.append{
                    switch self._state {
                    case .Pending:
                        abort()
                    case .Fulfilled(let value):
                        fulfiller(value as T)
                    case .Rejected(let error):
                        dispatch_async(q){
                            bind(error, fulfiller, rejecter)
                        }
                    }
                }
            }
        }
    }

    func finally(body:() -> Void) -> Promise<T> {
        let q = dispatch_get_main_queue()
        return dispatch_promise(to:q) { (fulfiller, rejecter) in
            switch self._state {
            case .Fulfilled(let value):
                body()
                fulfiller(value as T)
            case .Rejected(let error):
                body()
                rejecter(error)
            case .Pending:
                self._handlers.append{
                    body()
                    switch self._state {
                    case .Fulfilled(let value):
                        fulfiller(value as T)
                    case .Rejected(let error):
                        rejecter(error)
                    case .Pending:
                        abort()
                    }
                }
            }
        }
    }
}
