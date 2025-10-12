// ClosedRange+Distance.swift
import Foundation

extension ClosedRange where Bound: AdditiveArithmetic {
    var distance: Bound { upperBound - lowerBound }
}
