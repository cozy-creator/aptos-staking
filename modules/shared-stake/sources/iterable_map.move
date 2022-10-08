// TO DO: Add more methods and tests

module openrails::iterable_map {
    use std::vector;
    use aptos_std::simple_map::{Self, SimpleMap};

    struct IterableMap<Key, Value> has copy, drop, store {
        map: SimpleMap<Key, Value>,
        index: vector<Key>
    }

    public fun empty<Key: copy + drop + store, Value: store>(): IterableMap<Key, Value> {
        IterableMap {
            map: simple_map::create<Key, Value>(),
            index: vector::empty<Key>()
        }
    }

    public fun add<Key: copy + drop + store, Value: store>(iterable_map: &mut IterableMap<Key, Value>, key: Key, value: Value) {
        simple_map::add(&mut iterable_map.map, copy key, value);
        vector::push_back(&mut iterable_map.index, key);
    }

    public fun remove<Key: copy + drop + store, Value: store>(iterable_map: &mut IterableMap<Key, Value>, key: &Key): (Key, Value) {
        let (key, value) = simple_map::remove(&mut iterable_map.map, key);
        let (exists, index) = vector::index_of(&iterable_map.index, &key);
        if (exists) {
            let _ = vector::remove(&mut iterable_map.index, index);
        };
        (key, value)
    }

    public fun borrow<Key: store, Value: store>(iterable_map: &IterableMap<Key, Value>, key: &Key): &Value {
        simple_map::borrow(&iterable_map.map, key)
    }

    public fun borrow_mut<Key: store, Value: store>(iterable_map: &mut IterableMap<Key, Value>, key: &Key): &mut Value {
        simple_map::borrow_mut(&mut iterable_map.map, key)
    }

    public fun get_index<Key: store, Value: store>(iterable_map: &IterableMap<Key, Value>): &vector<Key> {
        &iterable_map.index
    }

    public fun contains_key<Key: store, Value: store>(iterable_map: &IterableMap<Key, Value>, key: &Key): bool {
        simple_map::contains_key(&iterable_map.map, key)
    }

    // Must contain at least 1 item, otherwise this aborts
    // If iter exceeds length of the vector, it loops back to 0 instead of abort
    public fun next<Key: store, Value: store>(iterable_map: &mut IterableMap<Key, Value>, iter: u64): (&Key, &mut Value) {
        if (iter >= vector::length(&iterable_map.index)) {
            iter = 0;
        };

        let key = vector::borrow(&iterable_map.index, iter);
        let value = simple_map::borrow_mut(&mut iterable_map.map, key);
        (key, value)
    }
}