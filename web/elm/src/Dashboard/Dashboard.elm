module Dashboard.Dashboard exposing
    ( documentTitle
    , handleCallback
    , handleDelivery
    , init
    , subscriptions
    , update
    , view
    )

import Application.Models exposing (Session)
import Concourse
import Concourse.Cli as Cli
import Dashboard.Details as Details
import Dashboard.Filter as Filter
import Dashboard.Footer as Footer
import Dashboard.Group as Group
import Dashboard.Group.Models exposing (Group, Pipeline)
import Dashboard.Models as Models exposing (DashboardError(..), DragState(..), DropState(..), Dropdown(..), Model, SubState)
import Dashboard.SearchBar as SearchBar
import Dashboard.Styles as Styles
import Dashboard.Text as Text
import Dict exposing (Dict)
import EffectTransformer exposing (ET)
import HoverState
import Html exposing (Html)
import Html.Attributes
    exposing
        ( attribute
        , class
        , download
        , href
        , id
        , src
        , style
        )
import Html.Events
    exposing
        ( onMouseEnter
        , onMouseLeave
        )
import List.Extra
import Login.Login as Login
import Message.Callback exposing (Callback(..))
import Message.Effects exposing (Effect(..))
import Message.Message as Message
    exposing
        ( DomID(..)
        , Message(..)
        , VisibilityAction(..)
        )
import Message.Subscription
    exposing
        ( Delivery(..)
        , Interval(..)
        , Subscription(..)
        )
import Monocle.Compose exposing (optionalWithLens, optionalWithOptional)
import Monocle.Lens
import Monocle.Optional
import MonocleHelpers exposing (bind, modifyWithEffect)
import RemoteData exposing (RemoteData)
import Routes
import ScreenSize exposing (ScreenSize(..))
import SideBar.SideBar as SideBar
import UserState
import Views.Styles


type alias Flags =
    { turbulencePath : String
    , searchType : Routes.SearchType
    , pipelineRunningKeyframes : String
    }


substateOptional : Monocle.Optional.Optional Model SubState
substateOptional =
    Monocle.Optional.Optional (.state >> RemoteData.toMaybe) (\s m -> { m | state = RemoteData.Success s })


init : Flags -> ( Model, List Effect )
init flags =
    ( { state = RemoteData.NotAsked
      , turbulencePath = flags.turbulencePath
      , pipelineRunningKeyframes = flags.pipelineRunningKeyframes
      , groups = []
      , hideFooter = False
      , hideFooterCounter = 0
      , showHelp = False
      , highDensity = flags.searchType == Routes.HighDensity
      , query = Routes.extractQuery flags.searchType
      , pipelinesWithResourceErrors = Dict.empty
      , existingJobs = []
      , pipelines = []
      , teams = []
      , isUserMenuExpanded = False
      , dropdown = Hidden
      }
    , [ FetchAllTeams
      , PinTeamNames Message.Effects.stickyHeaderConfig
      , GetScreenSize
      , FetchAllResources
      , FetchAllJobs
      , FetchAllPipelines
      ]
    )


handleCallback : Callback -> ET Model
handleCallback callback ( model, effects ) =
    case callback of
        AllTeamsFetched (Err _) ->
            ( { model
                | state =
                    RemoteData.Failure (Turbulence model.turbulencePath)
              }
            , effects
            )

        AllTeamsFetched (Ok ( now, teams )) ->
            let
                newModel =
                    case model.state of
                        RemoteData.Success substate ->
                            { model
                                | state =
                                    RemoteData.Success (Models.tick now substate)
                            }

                        _ ->
                            { model
                                | state =
                                    RemoteData.Success
                                        { now = now
                                        , dragState = Models.NotDragging
                                        , dropState = Models.NotDropping
                                        }
                            }
            in
            ( { newModel
                | groups =
                    List.map
                        (\team ->
                            { pipelines = []
                            , teamName = team.name
                            }
                        )
                        teams
                , teams = teams
              }
            , effects
            )

        AllJobsFetched (Ok allJobsInEntireCluster) ->
            ( { model | existingJobs = allJobsInEntireCluster }
            , effects
            )

        AllJobsFetched (Err _) ->
            ( { model
                | state =
                    RemoteData.Failure (Turbulence model.turbulencePath)
              }
            , effects
            )

        AllResourcesFetched (Ok resources) ->
            ( { model
                | pipelinesWithResourceErrors =
                    resources
                        |> List.foldr
                            (\r ->
                                Dict.update ( r.teamName, r.pipelineName )
                                    (Maybe.withDefault False
                                        >> (||) r.failingToCheck
                                        >> Just
                                    )
                            )
                            model.pipelinesWithResourceErrors
              }
            , effects
            )

        AllResourcesFetched (Err _) ->
            ( { model
                | state =
                    RemoteData.Failure (Turbulence model.turbulencePath)
              }
            , effects
            )

        AllPipelinesFetched (Ok allPipelinesInEntireCluster) ->
            ( { model
                | pipelines =
                    allPipelinesInEntireCluster
                        |> List.map
                            (\p ->
                                { id = p.id
                                , name = p.name
                                , teamName = p.teamName
                                , public = p.public
                                , isToggleLoading = False
                                , isVisibilityLoading = False
                                , paused = p.paused
                                }
                            )
              }
            , if List.isEmpty allPipelinesInEntireCluster then
                effects ++ [ ModifyUrl "/" ]

              else
                effects
            )

        AllPipelinesFetched (Err _) ->
            ( { model
                | state =
                    RemoteData.Failure (Turbulence model.turbulencePath)
              }
            , effects
            )

        LoggedOut (Ok ()) ->
            ( model
            , effects
                ++ [ NavigateTo <|
                        Routes.toString <|
                            Routes.dashboardRoute <|
                                model.highDensity
                   , FetchAllTeams
                   ]
            )

        PipelineToggled _ (Ok ()) ->
            ( model, effects ++ [ FetchAllPipelines ] )

        VisibilityChanged Hide pipelineId (Ok ()) ->
            ( updatePipeline
                (\p -> { p | public = False, isVisibilityLoading = False })
                pipelineId
                model
            , effects
            )

        VisibilityChanged Hide pipelineId (Err _) ->
            ( updatePipeline
                (\p -> { p | public = True, isVisibilityLoading = False })
                pipelineId
                model
            , effects
            )

        VisibilityChanged Expose pipelineId (Ok ()) ->
            ( updatePipeline
                (\p -> { p | public = True, isVisibilityLoading = False })
                pipelineId
                model
            , effects
            )

        VisibilityChanged Expose pipelineId (Err _) ->
            ( updatePipeline
                (\p -> { p | public = False, isVisibilityLoading = False })
                pipelineId
                model
            , effects
            )

        _ ->
            ( model, effects )


updatePipeline :
    (Pipeline -> Pipeline)
    -> Concourse.PipelineIdentifier
    -> Model
    -> Model
updatePipeline updater pipelineId model =
    { model
        | pipelines =
            model.pipelines
                |> List.Extra.updateIf
                    (\p ->
                        p.teamName == pipelineId.teamName && p.name == pipelineId.pipelineName
                    )
                    updater
    }


handleDelivery : Delivery -> ET Model
handleDelivery delivery =
    SearchBar.handleDelivery delivery
        >> Footer.handleDelivery delivery
        >> handleDeliveryBody delivery


handleDeliveryBody : Delivery -> ET Model
handleDeliveryBody delivery ( model, effects ) =
    case delivery of
        ClockTicked OneSecond time ->
            ( { model | state = RemoteData.map (Models.tick time) model.state }
            , effects
            )

        ClockTicked FiveSeconds _ ->
            ( model, effects ++ [ FetchAllTeams, FetchAllPipelines, FetchAllResources, FetchAllJobs ] )

        _ ->
            ( model, effects )


update : Session -> Message -> ET Model
update session msg =
    SearchBar.update session msg >> updateBody msg


updateBody : Message -> ET Model
updateBody msg ( model, effects ) =
    case msg of
        DragStart teamName index ->
            let
                newModel =
                    { model | state = RemoteData.map (\s -> { s | dragState = Models.Dragging teamName index }) model.state }
            in
            ( newModel, effects )

        DragOver _ index ->
            let
                newModel =
                    { model | state = RemoteData.map (\s -> { s | dropState = Models.Dropping index }) model.state }
            in
            ( newModel, effects )

        TooltipHd pipelineName teamName ->
            ( model, effects ++ [ ShowTooltipHd ( pipelineName, teamName ) ] )

        Tooltip pipelineName teamName ->
            ( model, effects ++ [ ShowTooltip ( pipelineName, teamName ) ] )

        DragEnd ->
            let
                updatePipelines :
                    ( Group.PipelineIndex, Group.PipelineIndex )
                    -> Group
                    -> ( Group, List Effect )
                updatePipelines ( dragIndex, dropIndex ) group =
                    let
                        newGroup =
                            Group.shiftPipelines dragIndex dropIndex group
                    in
                    ( newGroup
                    , [ SendOrderPipelinesRequest newGroup.teamName newGroup.pipelines ]
                    )

                dragDropOptional : Monocle.Optional.Optional Model ( Models.DragState, Models.DropState )
                dragDropOptional =
                    substateOptional
                        |> optionalWithLens
                            (Monocle.Lens.tuple
                                Details.dragStateLens
                                Details.dropStateLens
                            )

                dragDropIndexOptional : Monocle.Optional.Optional Model ( Group.PipelineIndex, Group.PipelineIndex )
                dragDropIndexOptional =
                    dragDropOptional
                        |> optionalWithOptional
                            (Monocle.Optional.zip
                                Group.dragIndexOptional
                                Group.dropIndexOptional
                            )

                groupsLens : Monocle.Lens.Lens Model (List Group)
                groupsLens =
                    Monocle.Lens.Lens .groups (\b a -> { a | groups = b })

                groupOptional : Monocle.Optional.Optional Model Group
                groupOptional =
                    -- the point of this optional is to find the group whose
                    -- name matches the name name in the dragstate
                    (substateOptional
                        |> optionalWithLens Details.dragStateLens
                        |> optionalWithOptional Group.teamNameOptional
                    )
                        |> bind
                            (\teamName ->
                                groupsLens
                                    |> Monocle.Optional.fromLens
                                    |> optionalWithOptional
                                        (Group.findGroupOptional teamName)
                            )

                bigOptional : Monocle.Optional.Optional Model ( ( Group.PipelineIndex, Group.PipelineIndex ), Group )
                bigOptional =
                    Monocle.Optional.tuple
                        dragDropIndexOptional
                        groupOptional

                ( newModel, unAccumulatedEffects ) =
                    model
                        |> modifyWithEffect bigOptional
                            (\( t, g ) ->
                                let
                                    ( newG, newMsg ) =
                                        updatePipelines t g
                                in
                                ( ( t, newG ), newMsg )
                            )
                        |> Tuple.mapFirst (dragDropOptional.set ( Models.NotDragging, Models.NotDropping ))
            in
            ( newModel, effects ++ unAccumulatedEffects )

        Click LogoutButton ->
            ( { model | teams = [], pipelines = [] }, effects )

        Click (PipelineButton pipelineId) ->
            let
                isPaused =
                    model.pipelines
                        |> List.Extra.find
                            (\p -> p.teamName == pipelineId.teamName && p.name == pipelineId.pipelineName)
                        |> Maybe.map .paused
            in
            case isPaused of
                Just ip ->
                    ( updatePipeline
                        (\p -> { p | isToggleLoading = True })
                        pipelineId
                        model
                    , effects
                        ++ [ SendTogglePipelineRequest pipelineId ip ]
                    )

                Nothing ->
                    ( model, effects )

        Click (VisibilityButton pipelineId) ->
            let
                isPublic =
                    model.pipelines
                        |> List.Extra.find
                            (\p -> p.teamName == pipelineId.teamName && p.name == pipelineId.pipelineName)
                        |> Maybe.map .public
            in
            case isPublic of
                Just public ->
                    ( updatePipeline
                        (\p -> { p | isVisibilityLoading = True })
                        pipelineId
                        model
                    , effects
                        ++ [ if public then
                                ChangeVisibility Hide pipelineId

                             else
                                ChangeVisibility Expose pipelineId
                           ]
                    )

                Nothing ->
                    ( model, effects )

        _ ->
            ( model, effects )


subscriptions : List Subscription
subscriptions =
    [ OnClockTick OneSecond
    , OnClockTick FiveSeconds
    , OnMouse
    , OnKeyDown
    , OnKeyUp
    , OnWindowResize
    ]


documentTitle : String
documentTitle =
    "Dashboard"


view : Session -> Model -> Html Message
view session model =
    Html.div
        (id "page-including-top-bar" :: Views.Styles.pageIncludingTopBar)
        [ topBar session model
        , Html.div
            [ id "page-below-top-bar"
            , style "padding-top" "54px"
            , style "box-sizing" "border-box"
            , style "display" "flex"
            , style "height" "100%"
            , style "padding-bottom" <|
                if model.showHelp || model.hideFooter then
                    "0"

                else
                    "50px"
            ]
          <|
            [ SideBar.view session Nothing
            , dashboardView session model
            ]
        , Footer.view session model
        ]


topBar : Session -> Model -> Html Message
topBar session model =
    Html.div
        (id "top-bar-app" :: Views.Styles.topBar False)
    <|
        [ Html.div [ style "display" "flex", style "align-items" "center" ]
            [ SideBar.hamburgerMenu session
            , Html.a (href "/" :: Views.Styles.concourseLogo) []
            , clusterNameView session
            ]
        ]
            ++ (let
                    isDropDownHidden =
                        model.dropdown == Hidden

                    isMobile =
                        session.screenSize == ScreenSize.Mobile
                in
                if
                    not model.highDensity
                        && isMobile
                        && (not isDropDownHidden || model.query /= "")
                then
                    [ SearchBar.view session model ]

                else if not model.highDensity then
                    [ SearchBar.view session model
                    , Login.view session.userState model False
                    ]

                else
                    [ Login.view session.userState model False ]
               )


clusterNameView : Session -> Html Message
clusterNameView session =
    Html.div
        Styles.clusterName
        [ Html.text session.clusterName ]


dashboardView :
    { a
        | hovered : HoverState.HoverState
        , screenSize : ScreenSize
        , userState : UserState.UserState
    }
    -> Model
    -> Html Message
dashboardView session model =
    case model.state of
        RemoteData.Failure (Turbulence path) ->
            turbulenceView path

        _ ->
            Html.div
                (class (.pageBodyClass Message.Effects.stickyHeaderConfig)
                    :: Styles.content model.highDensity
                )
            <|
                welcomeCard session model
                    :: pipelinesView
                        session
                        { teams = model.teams
                        , substate = model.state
                        , query = model.query
                        , hovered = session.hovered
                        , pipelineRunningKeyframes =
                            model.pipelineRunningKeyframes
                        , highDensity = model.highDensity
                        , pipelinesWithResourceErrors = model.pipelinesWithResourceErrors
                        , existingJobs = model.existingJobs
                        , pipelines = model.pipelines
                        }


welcomeCard :
    { a | hovered : HoverState.HoverState, userState : UserState.UserState }
    -> { b | pipelines : List Pipeline }
    -> Html Message
welcomeCard session { pipelines } =
    let
        cliIcon : HoverState.HoverState -> Cli.Cli -> Html Message
        cliIcon hoverable cli =
            Html.a
                ([ href <| Cli.downloadUrl cli
                 , attribute "aria-label" <| Cli.label cli
                 , id <| "top-cli-" ++ Cli.id cli
                 , onMouseEnter <| Hover <| Just <| Message.WelcomeCardCliIcon cli
                 , onMouseLeave <| Hover Nothing
                 , download ""
                 ]
                    ++ Styles.topCliIcon
                        { hovered =
                            HoverState.isHovered
                                (Message.WelcomeCardCliIcon cli)
                                hoverable
                        , cli = cli
                        }
                )
                []
    in
    if List.isEmpty pipelines then
        Html.div
            (id "welcome-card" :: Styles.welcomeCard)
            [ Html.div
                Styles.welcomeCardTitle
                [ Html.text Text.welcome ]
            , Html.div
                Styles.welcomeCardBody
              <|
                [ Html.div
                    [ style "display" "flex"
                    , style "align-items" "center"
                    ]
                  <|
                    [ Html.div
                        [ style "margin-right" "10px" ]
                        [ Html.text Text.cliInstructions ]
                    ]
                        ++ List.map (cliIcon session.hovered) Cli.clis
                , Html.div
                    []
                    [ Html.text Text.setPipelineInstructions ]
                ]
                    ++ loginInstruction session.userState
            , Html.pre
                Styles.asciiArt
                [ Html.text Text.asciiArt ]
            ]

    else
        Html.text ""


loginInstruction : UserState.UserState -> List (Html Message)
loginInstruction userState =
    case userState of
        UserState.UserStateLoggedIn _ ->
            []

        _ ->
            [ Html.div
                [ id "login-instruction"
                , style "line-height" "42px"
                ]
                [ Html.text "login "
                , Html.a
                    [ href "/login"
                    , style "text-decoration" "underline"
                    ]
                    [ Html.text "here" ]
                ]
            ]


noResultsView : String -> Html Message
noResultsView query =
    let
        boldedQuery =
            Html.span [ class "monospace-bold" ] [ Html.text query ]
    in
    Html.div
        (class "no-results" :: Styles.noResults)
        [ Html.text "No results for "
        , boldedQuery
        , Html.text " matched your search."
        ]


turbulenceView : String -> Html Message
turbulenceView path =
    Html.div
        [ class "error-message" ]
        [ Html.div [ class "message" ]
            [ Html.img [ src path, class "seatbelt" ] []
            , Html.p [] [ Html.text "experiencing turbulence" ]
            , Html.p [ class "explanation" ] []
            ]
        ]


pipelinesView :
    { a | userState : UserState.UserState }
    ->
        { teams : List Concourse.Team
        , substate : RemoteData DashboardError Models.SubState
        , hovered : HoverState.HoverState
        , pipelineRunningKeyframes : String
        , query : String
        , highDensity : Bool
        , pipelinesWithResourceErrors : Dict ( String, String ) Bool
        , existingJobs : List Concourse.Job
        , pipelines : List Pipeline
        }
    -> List (Html Message)
pipelinesView session params =
    let
        filteredGroups =
            Filter.filterGroups params.existingJobs params.query params.teams params.pipelines
                |> List.sortWith (Group.ordering session)

        groupViews =
            if params.highDensity then
                filteredGroups
                    |> List.concatMap
                        (Group.hdView
                            { pipelineRunningKeyframes = params.pipelineRunningKeyframes
                            , pipelinesWithResourceErrors = params.pipelinesWithResourceErrors
                            , existingJobs = params.existingJobs
                            , pipelines = params.pipelines
                            }
                            session
                        )

            else
                filteredGroups
                    |> List.map
                        (Group.view
                            session
                            { dragState =
                                RemoteData.map .dragState params.substate
                                    |> RemoteData.withDefault NotDragging
                            , dropState =
                                RemoteData.map .dropState params.substate
                                    |> RemoteData.withDefault NotDropping
                            , now = RemoteData.map .now params.substate
                            , hovered = params.hovered
                            , pipelineRunningKeyframes = params.pipelineRunningKeyframes
                            , pipelinesWithResourceErrors = params.pipelinesWithResourceErrors
                            , existingJobs = params.existingJobs
                            , pipelines = params.pipelines
                            }
                        )
    in
    if List.isEmpty groupViews && not (String.isEmpty params.query) then
        [ noResultsView params.query ]

    else
        groupViews
