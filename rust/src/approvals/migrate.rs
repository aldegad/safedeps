//! The migration: approvals a check made before this store, moved into it
//! from advisory.log (`safedeps-core approvals migrate`). Its rows come
//! first; the migration is the next commit's.

#[cfg(test)]
mod tests;
