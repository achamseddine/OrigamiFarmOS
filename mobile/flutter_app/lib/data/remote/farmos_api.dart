import 'api_client.dart';

/// One method per endpoint this app actually calls, grouped and named to
/// match ../../../../../OrigamiFarmServer/docs/FARMOS_API.md exactly (same
/// paths, same field names on the way in and out) so a repository reading
/// this file can cross-check it against that contract directly.
///
/// Every method returns decoded JSON (`Map<String, dynamic>` or
/// `List<dynamic>`) rather than a typed model — turning that into this
/// app's own domain entities (lib/domain/entities/) is each repository's
/// job, the same split the server itself draws between its ORM rows and
/// its wire schemas.
class FarmosApi {
  FarmosApi(this._client);
  final ApiClient _client;

  // --- Auth ------------------------------------------------------------

  Future<String> login({required String email, required String password}) async {
    final result = await _client.post('/auth/login', body: {'email': email, 'password': password});
    return result['access_token'] as String;
  }

  Future<Map<String, dynamic>> me() async => (await _client.get('/auth/me')) as Map<String, dynamic>;

  // --- Animals -----------------------------------------------------------

  Future<List<dynamic>> listAnimals(String farmId) async =>
      (await _client.get('/animals', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createAnimal(Map<String, dynamic> body) async =>
      (await _client.post('/animals', body: body)) as Map<String, dynamic>;

  Future<Map<String, dynamic>> moveAnimal(String animalId, String locationLabel) async =>
      (await _client.patch('/animals/$animalId', body: {'location_label': locationLabel}))
          as Map<String, dynamic>;

  // --- Observations --------------------------------------------------------

  Future<List<dynamic>> listObservations(
    String farmId, {
    String? entityType,
    String? entityId,
  }) async =>
      (await _client.get('/observations', query: {
        'farm_id': farmId,
        'entity_type': entityType,
        'entity_id': entityId,
      })) as List<dynamic>;

  Future<Map<String, dynamic>> createObservation(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/observations', body: body, idempotencyKey: idempotencyKey))
          as Map<String, dynamic>;

  // --- Animal health ---------------------------------------------------

  Future<List<dynamic>> listTreatments(String farmId) async =>
      (await _client.get('/health/treatments', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createTreatment(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/health/treatments', body: body, idempotencyKey: idempotencyKey))
          as Map<String, dynamic>;

  // --- Feed & inventory --------------------------------------------------

  Future<List<dynamic>> listFeedItems(String farmId) async =>
      (await _client.get('/feed/items', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createFeedItem(Map<String, dynamic> body) async =>
      (await _client.post('/feed/items', body: body)) as Map<String, dynamic>;

  Future<List<dynamic>> listFeedTransactions(String farmId, {String? itemId}) async =>
      (await _client.get('/feed/transactions', query: {'farm_id': farmId, 'item_id': itemId}))
          as List<dynamic>;

  Future<Map<String, dynamic>> createFeedTransaction(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/feed/transactions', body: body, idempotencyKey: idempotencyKey))
          as Map<String, dynamic>;

  // --- Production ----------------------------------------------------------

  Future<List<dynamic>> listMilkRecords(String farmId) async =>
      (await _client.get('/production/milk', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createMilkRecord(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/production/milk', body: body, idempotencyKey: idempotencyKey))
          as Map<String, dynamic>;

  Future<List<dynamic>> listEggRecords(String farmId) async =>
      (await _client.get('/production/eggs', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createEggRecord(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/production/eggs', body: body, idempotencyKey: idempotencyKey))
          as Map<String, dynamic>;

  Future<List<dynamic>> listHarvestRecords(String farmId) async =>
      (await _client.get('/production/harvest', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createHarvestRecord(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/production/harvest', body: body, idempotencyKey: idempotencyKey))
          as Map<String, dynamic>;

  Future<List<dynamic>> listFields(String farmId) async =>
      (await _client.get('/production/fields', query: {'farm_id': farmId})) as List<dynamic>;

  // --- Sales & finance -----------------------------------------------------

  Future<List<dynamic>> listExpenses(String farmId) async =>
      (await _client.get('/expenses', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createExpense(Map<String, dynamic> body) async =>
      (await _client.post('/expenses', body: body)) as Map<String, dynamic>;

  Future<List<dynamic>> listSales(String farmId) async =>
      (await _client.get('/sales', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createSale(Map<String, dynamic> body) async =>
      (await _client.post('/sales', body: body)) as Map<String, dynamic>;

  // --- Tasks ---------------------------------------------------------------

  Future<List<dynamic>> listTasks(String farmId) async =>
      (await _client.get('/tasks', query: {'farm_id': farmId})) as List<dynamic>;

  Future<Map<String, dynamic>> createTask(Map<String, dynamic> body, {String? idempotencyKey}) async =>
      (await _client.post('/tasks', body: body, idempotencyKey: idempotencyKey)) as Map<String, dynamic>;

  Future<Map<String, dynamic>> updateTask(String taskId, Map<String, dynamic> body) async =>
      (await _client.patch('/tasks/$taskId', body: body)) as Map<String, dynamic>;

  // --- Notifications, priorities, reports, recommendations ----------------

  Future<Map<String, dynamic>> listNotifications({bool unreadOnly = false}) async =>
      (await _client.get('/notifications', query: {'unread_only': unreadOnly})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> markNotificationRead(String notificationId) async =>
      (await _client.post('/notifications/$notificationId/read')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> listPriorities(String farmId) async =>
      (await _client.get('/priorities', query: {'farm_id': farmId})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> morningBriefing(String farmId) async =>
      (await _client.get('/morning-briefing', query: {'farm_id': farmId})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> dailySummary(String farmId) async =>
      (await _client.get('/reports/daily-summary', query: {'farm_id': farmId})) as Map<String, dynamic>;

  Future<List<dynamic>> listRecommendations(String farmId) async =>
      (await _client.get('/recommendations', query: {'farm_id': farmId})) as List<dynamic>;
}
