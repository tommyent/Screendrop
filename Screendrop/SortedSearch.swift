//
//  SortedSearch.swift
//  Screendrop
//

nonisolated extension Array {
    /// Index of the last element whose key is at or before `value`, found by
    /// binary search over an array sorted ascending by `key`. Among equal
    /// keys it picks the last one. Nil when the array is empty or every key
    /// is later than `value`.
    func lastIndex(atOrBefore value: Double, by key: (Element) -> Double) -> Int? {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if key(self[middle]) <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }
}
