pub use hyperswitch_domain_models::{
    configs::{self, ConfigInterface},
    errors::api_error_response,
};

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use std::sync::Arc;

    use diesel::{Connection, ExpressionMethods, PgConnection, QueryDsl, RunQueryDsl};
    use diesel_models::{configs::ConfigNew, schema::configs::dsl};
    use hyperswitch_masking::PeekInterface;
    use storage_impl::redis::cache::{CacheKey, CONFIG_CACHE};
    use tokio::sync::oneshot;

    use crate::{
        db::StorageInterface,
        routes::{
            self,
            app::{settings::Settings, StorageImpl},
        },
        services,
    };

    async fn evict_cached_config(db: &dyn StorageInterface, key: &str) {
        let redis_conn = db.get_redis_conn().unwrap();
        CONFIG_CACHE
            .remove(CacheKey {
                key: key.to_string(),
                prefix: redis_conn.redis_conn.key_prefix.clone(),
            })
            .await;
        redis_conn.delete_key(&key.into()).await.unwrap();
    }

    #[tokio::test]
    #[cfg(feature = "v1")]
    async fn test_missing_config_key_is_served_from_cache() {
        let conf = Settings::new().unwrap();
        let database = conf.master_database.get_inner();
        let database_url = format!(
            "postgres://{}:{}@{}:{}/{}",
            database.username,
            database.password.peek(),
            database.host,
            database.port,
            database.dbname
        );
        let tx: oneshot::Sender<()> = oneshot::channel().0;
        let app_state = Box::pin(routes::AppState::with_storage(
            conf,
            StorageImpl::PostgresqlTest,
            tx,
            Box::new(services::MockApiClient),
            env!("CARGO_PKG_NAME"),
        ))
        .await;
        let state = Arc::new(app_state)
            .get_session_state(
                &common_utils::id_type::TenantId::try_from_string("public".to_string()).unwrap(),
                None,
                || {},
            )
            .unwrap();
        let db = &*state.store;
        let key = format!(
            "test_missing_config_{}",
            common_utils::generate_id_with_len(16)
        );

        assert!(db
            .find_config_by_key_optional(&key)
            .await
            .unwrap()
            .is_none());

        let cached_miss = CONFIG_CACHE
            .get_val::<Option<diesel_models::configs::Config>>(CacheKey {
                key: key.clone(),
                prefix: db.get_redis_conn().unwrap().redis_conn.key_prefix.clone(),
            })
            .await;
        assert!(matches!(cached_miss, Some(None)));

        // Written on a connection outside the store, so the cached miss is not invalidated.
        let mut raw_conn = PgConnection::establish(&database_url).unwrap();
        diesel::insert_into(dsl::configs)
            .values(ConfigNew {
                key: key.clone(),
                config: "inserted_behind_cache".to_string(),
            })
            .execute(&mut raw_conn)
            .unwrap();

        let second_lookup = db.find_config_by_key_optional(&key).await;

        evict_cached_config(db, &key).await;
        let after_eviction = db.find_config_by_key_optional(&key).await;

        diesel::delete(dsl::configs.filter(dsl::key.eq(&key)))
            .execute(&mut raw_conn)
            .unwrap();
        evict_cached_config(db, &key).await;

        assert!(
            second_lookup.unwrap().is_none(),
            "second lookup of a missing key must be served from cache, not Postgres"
        );
        assert_eq!(
            after_eviction.unwrap().map(|config| config.config),
            Some("inserted_behind_cache".to_string()),
        );
    }
}
