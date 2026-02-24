//
//  KeyEvent.swift
//  HexCore
//
//  Created by Kit Langton on 1/28/25.
//

import Sauce

public enum InputEvent {
    case keyboard(KeyEvent)
    case mouseClick
    case mouseButton(Int)  // button number (3 = back, 4 = forward on most mice)
    case leftDoubleClick
    case rightDoubleClick
}

public struct KeyEvent {
    public let key: Key?
    public let modifiers: Modifiers
    
    public init(key: Key?, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
