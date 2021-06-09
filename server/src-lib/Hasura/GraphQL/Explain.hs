module Hasura.GraphQL.Explain
  ( explainGQLQuery
  , GQLExplain
  ) where

import           Hasura.Prelude

import qualified Data.Aeson                             as J
import qualified Data.Aeson.TH                          as J
import qualified Data.HashMap.Strict                    as Map
import qualified Data.HashMap.Strict.InsOrd             as OMap
import qualified Language.GraphQL.Draft.Syntax          as G

import           Control.Monad.Trans.Control            (MonadBaseControl)

import qualified Hasura.GraphQL.Execute                 as E
import qualified Hasura.GraphQL.Execute.Action          as E
import qualified Hasura.GraphQL.Execute.Query           as E
import qualified Hasura.GraphQL.Transport.HTTP.Protocol as GH
import qualified Hasura.SQL.AnyBackend                  as AB

import           Hasura.Base.Error
import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Execute.Backend
import           Hasura.GraphQL.Execute.Instances       ()
import           Hasura.GraphQL.Parser
import           Hasura.GraphQL.Transport.Backend
import           Hasura.GraphQL.Transport.Instances     ()
import           Hasura.Metadata.Class
import           Hasura.RQL.Types
import           Hasura.Session


data GQLExplain
  = GQLExplain
  { _gqeQuery   :: !GH.GQLReqParsed
  , _gqeUser    :: !(Maybe (Map.HashMap Text Text))
  , _gqeIsRelay :: !(Maybe Bool)
  } deriving (Show, Eq)

$(J.deriveJSON hasuraJSON{J.omitNothingFields=True}
  ''GQLExplain
 )

-- NOTE: This function has a 'MonadTrace' constraint in master, but we don't need it
-- here. We should evaluate if we need it here.
explainQueryField
  :: ( MonadError QErr m
     , MonadIO m
     )
  => UserInfo
  -> G.Name
  -> QueryRootField UnpreparedValue
  -> m EncJSON
explainQueryField userInfo fieldName rootField = do
  case rootField of
    RFRemote _ -> throw400 InvalidParams "only hasura queries can be explained"
    RFAction _ -> throw400 InvalidParams "query actions cannot be explained"
    RFRaw _    -> pure $ encJFromJValue $ ExplainPlan fieldName Nothing Nothing
    RFDB sourceName exists   -> do
      step <- AB.dispatchAnyBackend @BackendExecute exists
        \(SourceConfigWith sourceConfig (QDBR db)) ->
           mkDBQueryExplain fieldName userInfo sourceName sourceConfig db
      AB.dispatchAnyBackend @BackendTransport step runDBQueryExplain


-- NOTE: This function has a 'MonadTrace' constraint in master, but we don't need it
-- here. We should evaluate if we need it here.
explainGQLQuery
  :: forall m
  . ( MonadError QErr m
    , MonadIO m
    , MonadBaseControl IO m
    , MonadMetadataStorage (MetadataStorageT m)
    )
  => SchemaCache
  -> GQLExplain
  -> m EncJSON
explainGQLQuery sc (GQLExplain query userVarsRaw maybeIsRelay) = do
  -- NOTE!: we will be executing what follows as though admin role. See e.g. notes in explainField:
  userInfo <-
    mkUserInfo (URBFromSessionVariablesFallback adminRoleName) UAdminSecretSent
               sessionVariables
  -- we don't need to check in allow list as we consider it an admin endpoint
  (graphQLContext, queryParts) <- E.getExecPlanPartial userInfo sc queryType query
  case queryParts of
    G.TypedOperationDefinition G.OperationTypeQuery _ varDefs directives inlinedSelSet -> do
      (unpreparedQueries, _, _, _) <-
        E.parseGraphQLQuery graphQLContext varDefs (GH._grVariables query) directives inlinedSelSet
        -- TODO: validate directives here
      encJFromList <$>
        for (OMap.toList unpreparedQueries) (uncurry (explainQueryField userInfo))

    G.TypedOperationDefinition G.OperationTypeMutation _ _ _ _ ->
      throw400 InvalidParams "only queries can be explained"

    G.TypedOperationDefinition G.OperationTypeSubscription _ varDefs directives inlinedSelSet -> do
      (unpreparedQueries, _, _, _) <- E.parseGraphQLQuery graphQLContext varDefs (GH._grVariables query) directives inlinedSelSet
      validSubscription <-  E.buildSubscriptionPlan userInfo unpreparedQueries
      case validSubscription of
        E.SEAsyncActionsWithNoRelationships _ -> throw400 NotSupported "async action query fields without relationships to table cannot be explained"
        E.SEOnSourceDB actionIds liveQueryBuilder -> do
          actionLogResponseMap <- fst <$> E.fetchActionLogResponses actionIds
          (_, E.LQP exists) <- liftEitherM $ liftIO $ runExceptT $ liveQueryBuilder actionLogResponseMap
          AB.dispatchAnyBackend @BackendExecute exists \(E.MultiplexedLiveQueryPlan execPlan) ->
            encJFromJValue <$> mkLiveQueryExplain execPlan
  where
    queryType = bool E.QueryHasura E.QueryRelay $ Just True == maybeIsRelay
    sessionVariables = mkSessionVariablesText $ fromMaybe mempty userVarsRaw
