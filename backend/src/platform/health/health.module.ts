import { Controller, Get, Module } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
@ApiTags('platform') @Controller('health') class HealthController {@Get() health(){return {status:'ok',service:'origami-farmos-backend'};}}
@Module({controllers:[HealthController]}) export class HealthModule {}
